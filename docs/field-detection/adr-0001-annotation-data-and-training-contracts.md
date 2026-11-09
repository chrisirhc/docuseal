# ADR 0001: Annotation, data ownership, and training contracts

- Status: Accepted. See [Decision log](#decision-log)
- Issue: BSF-94
- Project: P-BSF-11, DocuSeal field detection memory and fine-tuning

Milestone 1 stores provenance only and never trains. The training rules below
bind the milestones that do.

## Decision log

| Date | Decision |
| --- | --- |
| 2026-11-09 | Training uses the blank source document of a template that has been signed, with the field metadata the form maker set up. Filled-in values never enter training |
| 2026-11-09 | Training runs on the self-hosted instance. No data leaves the instance, and there is no central or shared training service |
| 2026-11-09 | Admins can turn off provenance capture for their account. It is on by default |
| 2026-11-09 | An account admin turns training on. Users then opt in templates they created |
| 2026-11-09 | Provenance is kept for as long as its template exists. Admins can clear an account's provenance at any time |
| 2026-11-09 | A deleted source is left out of the next training run. It does not force an immediate retrain |

## Context

Template fields are authoring objects. A field in `templates.fields` can be
moved, resized, retyped, renamed, or deleted for reasons unrelated to what is
printed on the page. Today nothing records what the detector proposed, so a
saved template cannot tell us whether the detector was right.

`template_versions` is not a substitute. It snapshots authoring state on demand
and has no prediction provenance or review state.

We need four kinds of truth, and they must not be collapsed into one record:

1. What the detector and heuristics proposed. This never changes.
2. What the author did to those proposals.
3. What a reviewer asserted about the page.
4. What a training dataset and model were built from.

## Decision

Add a separate, append-mostly provenance domain beside templates. Templates do
not gain review metadata, so existing templates need no migration and remain
fully usable.

### Records

| Record | Purpose | Mutability | Introduced by |
| --- | --- | --- | --- |
| Detection run | One detector execution over one document | Open while running, then frozen | BSF-96 |
| Detection run page | Evidence that one page was processed, with its geometry | Immutable | BSF-96 |
| Prediction | One detector box or one final suggestion | Immutable | BSF-96 |
| Correction | One author change to a suggestion | Append-only | BSF-97 |
| Reviewed annotation | A reviewer's assertion about one target on a page | Superseded, never edited | BSF-97 |
| Page review | The review state of one page of one document | Append-only history | BSF-97 |
| Dataset version | Immutable manifest of reviewed annotations | Immutable | BSF-99 |
| Training run | One reproducible offline training execution | Frozen on completion | BSF-100 |
| Model artifact | One registered ONNX file and its gate results | Status changes only | BSF-103 |

### Detection run

`detection_runs`, one row per document per request.

- `uuid`, `account_id`, `template_id`, `user_id`.
- `attachment_uuid`: a string, not a foreign key, so provenance outlives a
  replaced attachment until the template is destroyed or an admin clears it.
- `request_uuid`, `attempt`: see [Idempotency](#idempotency).
- `page`: the requested page, or null for the whole document.
- `status`: `running`, `completed`, or `failed`.
- `source_sha256`, `source_byte_size`, `source_kind` (`pdf` or `image`).
- `model_sha256`, `model_version` (`v1` or `v2` input signature).
- `preprocessing_version`, `schema_version`.
- `parameters`: thresholds and rendering options as JSON text.
- `error_class`, `started_at`, `finished_at`.

### Prediction

`detection_predictions`, one row per box.

- `stage`: `detector` or `suggestion`.
  - `detector` is the output of `Templates::ImageToFields`, after its internal
    non-maximum suppression and merging and before any page heuristic. It is the
    earliest output available without changing inference. It is not the raw
    tensor. The confidence floor is recorded in `parameters`.
  - `suggestion` is the field offered to the author.
- `detection_position`: on a suggestion, the `position` of the `detector` row it
  came from, on the same run and page. A position rather than a row ID lets a
  page be bulk-inserted on every supported database.
- `uuid`: on a suggestion, equal to the `uuid` of the field streamed to the
  client.
- `page`, `position`, `field_type`, `x`, `y`, `w`, `h`, `confidence`.

Heuristics can raise confidence and can change a type. Both values are kept, so
the comparison between `detector` and `suggestion` rows shows each adjustment.
A suggestion's `confidence` is a ranking score, not a probability: the overlap
heuristic adds `1.0` to it, so it can exceed 1. Calibration work must use
`detector` rows.
Detector rows that a threshold rejected have no suggestion child.

### Linking saved fields

A suggestion's `uuid` is the field `uuid`. A saved field links to its prediction
through `(template_id, uuid)`, with no change to the template schema or to the
fields API. The builder keeps streamed UUIDs, and copied fields receive new ones,
so a copy is correctly not a prediction.

A cloned template has no link to the original's predictions. This is intended:
cloning crosses a review boundary, and the clone starts as unreviewed.

### Correction

One row per observed change, referencing the suggestion:

- `kind`: `move`, `resize`, `retype`, `reassign_signer`, `delete`, or `add`.
- `before` and `after` geometry and type, and the acting user.

A correction is evidence, not truth. It enters training only through a reviewed
annotation.

### Reviewed annotation

One row per target on a reviewed page:

- `blank_geometry`: where the blank is printed. Used for visual localization.
- `input_geometry`: the rectangle a signer types or signs in. Used for product
  behavior.
- `localization_class`: `text` or `checkbox`. This is what the detector is
  trained on, and it is deliberately limited to visual classes.
- `semantic_type`: `text`, `date`, `signature`, `number`, and so on.
- `field_name`: the name the form maker gave the field, such as "Name". Optional.
- `signer_role`: optional, and independent of the type.
- `disposition`: see [Dispositions](#dispositions).
- `supersedes_id`: corrections to a review create a new row.

The two geometries differ in practice. A signature line is a thin printed rule,
but the signing area is a tall box above it. The heuristics already make this
adjustment, in `extract_line_fields_from_page`. Training on input geometry would
teach the detector to predict empty space.

Semantic type, field name, and signer role are never detector classes. They
belong to the separate stage evaluated in BSF-102.

### Coordinates

All geometry uses `x`, `y`, `w`, `h` normalized to `0..1`.

- The origin is the top-left of the page **as displayed**, after the PDF
  `/Rotate` value is applied. This matches `FPDF_RenderPageBitmap`, called with a
  rotation of `0`, and matches template field areas.
- Coordinates are relative to the page, not to the trimmed or padded model input.
- For an image document, the page is the stored preview, which is what the
  detector sees.
- `detection_run_pages` records `page_width`, `page_height`, `rotation`,
  `image_width`, and `image_height`, so any box can be mapped back to source
  pixels or points.
- `w` and `h` are positive. Precision is single float at inference and stored as
  double.

### Source fingerprints

`source_sha256` is the SHA-256 of the exact bytes given to the detector.

- It is not `active_storage_blobs.checksum`, which is MD5 and describes the
  uploaded blob. For an image document, the bytes are the preview, not the blob.
- It identifies bytes only. Layout-level similarity is a separate concern for
  BSF-105 and needs its own versioned fingerprint.
- Exact reuse in BSF-98 matches `(account_id, source_sha256, page)`.

### Versions

| Version | Changes when |
| --- | --- |
| `schema_version` | The meaning of a stored prediction or geometry changes |
| `preprocessing_version` | Rendering, trimming, padding, or heuristics change what a model sees or what it returns |
| `model_sha256` | The ONNX file changes |

Two runs are comparable only if all three match or the difference is the subject
of the comparison. `preprocessing_version` is a constant in
`lib/detection_runs.rb`, and changing detector code without bumping it is a bug.

### Dispositions

Absence from a saved template proves nothing, so a reviewed target records why.

| Disposition | Meaning | Training use |
| --- | --- | --- |
| `used` | A real field that the workflow uses | Positive |
| `valid_unused` | A real blank that this workflow leaves empty | Positive |
| `false_detection` | Nothing fillable is printed here | Negative evidence |
| `ignored` | Ambiguous, or the reviewer declines to judge | Excluded region |

### Page review states

| State | Meaning | Training use |
| --- | --- | --- |
| `unreviewed` | The default. No assertion | Not used |
| `partial` | Listed targets are correct, and the page may hold others | Listed positives only. Unlabeled regions are masked, never background |
| `complete` | Every target on the page is annotated | Positives, and unlabeled regions are valid background |

Only `complete` pages produce background negatives. The following never imply
review on their own: saving a template, sending a template, deleting a field, or
leaving a blank unused.

### Idempotency

The client generates a `request_uuid` per user action. One request creates one
run per document, unique on `(template_id, request_uuid, attachment_uuid, attempt)`.

| Situation | Behavior |
| --- | --- |
| Same request, run completed | Duplicate delivery. Replay stored results with the same IDs and run no inference |
| Same request, run in progress | Duplicate delivery. Return an error event and run no inference |
| Same request, run failed or stale | Retry. Create the next `attempt` |
| New request, same source | Rerun. Create a new run with new prediction IDs |
| No `request_uuid` | Treated as a rerun, for compatibility with older clients |

A `running` run older than 15 minutes is stale.

### Failure independence

Provenance must never break detection. If writing provenance fails, the failure
is logged and the stream continues with the same field data. Those fields then
have no linked prediction, which reads as an unreviewed, unattributed result.

Failed runs keep the pages that finished, because those pages were delivered.

## Data ownership

### Isolation

Every record carries `account_id`, directly or through its run. All reads go
through account-scoped authorization. Linked and testing accounts are separate
accounts for this purpose, and template sharing grants no access to provenance.

### Training sources

Training learns how a form maker sets up a form. It never learns from the people
who fill it in.

| Used for training | Never used for training |
| --- | --- |
| The blank source document a form maker uploaded | Completed or signed PDFs |
| Field geometry, type, name, and signer role as the form maker set them | Values signers entered, including signatures, initials, and attachments |
| Reviewed annotations and corrections | Submitter names, emails, phone numbers, and audit trails |

A template is eligible only after at least one of its submissions has been
completed. A completed signing shows the field setup worked in practice. The
training example is still the blank document and its template fields, never the
submission.

Learning from form filling is a separate use case with its own consent and
pipeline. It is out of scope for this project.

### Training location

Training runs on the self-hosted instance, as an offline job. Training data,
models, and logs stay on that instance. There is no central collection service,
no upload path, and no model shared between instances. Each instance starts from
the stock model and fine-tunes it on its own opted-in examples.

This differs from Frigate+, which trains centrally. Only the opt-in,
verified-example workflow is borrowed from it.

One instance can host several accounts. The model's job is to find blanks and
checkboxes, and it holds no text, so it can be shared across the accounts on an
instance. Field names are text, and they could reveal one account's forms to
another. Suggestions for field names and signer roles in BSF-102 therefore use
only examples from the requesting account.

### Data minimization

Provenance stores geometry, types, scores, and hashes. It stores no document
text, field names, field values, or submitter data, and it contains no data from
submissions. Reviewed annotations add the form maker's field names, which come
from the template rather than from any signer. The source bytes stay in Active
Storage under existing controls. Dataset versions reference sources by hash and
materialize page images only inside the instance's training directory.

### Provenance capture

Capture is not training use. It records what the detector suggested, stays
within the account like the template, and is on by default. An account admin can
turn it off with the **Record field detection results** setting, stored as the
`record_field_detections` account config. When it is off, detection behaves as
it did before BSF-96: no runs are recorded, and the stream carries no
`detection_run_uuid`. Turning it off does not delete runs that were already
recorded.

### Training authorization

Training use is granted in two steps:

- The default is off.
- An account admin turns on training for the account. Until then, no user's
  documents are eligible.
- Each user then opts in templates they created. A user's choice never covers
  another user's templates.
- Each page review records the authorization in force when it was made.
- Revocation is forward-looking for trained artifacts, and removes the template
  or account from future dataset versions. See [Deletion](#deletion-and-lineage).

### Access control

| Actor | Access |
| --- | --- |
| Template editor | Own account's predictions, and may correct and review |
| Account admin | Account-wide provenance, the capture setting, clearing provenance, and the training setting |
| Training job | Runs on the instance and reads only dataset versions built from authorized reviews |
| Other accounts | None |

### Retention

- Detection runs, pages, and predictions: the life of the template. There is
  no time-based expiry.
- An account admin can clear all of the account's detection runs from account
  settings, next to the capture setting. Clearing removes runs, pages, and
  predictions in one step. It does not touch templates or fields, and it does
  not change the capture setting. Saved fields keep their UUIDs, but they no
  longer link to a prediction.
- Clearing removes cleared runs from future dataset versions. Artifacts already
  trained follow [Deletion and lineage](#deletion-and-lineage).
- Dataset versions: while any artifact built from them is deployed, plus 1 year.
- Training logs and metrics: indefinitely. They hold no document content.

### Deletion and lineage

| Event | Effect |
| --- | --- |
| Field deleted | Predictions are kept. The deletion is a correction, not a review |
| Attachment replaced | The run keeps its fingerprint until the template is destroyed or provenance is cleared |
| Provenance cleared | Runs, pages, and predictions of the account are deleted |
| Template archived | No effect, because archiving can be reversed |
| Template destroyed | Runs, pages, predictions, corrections, and reviews are deleted |
| Account destroyed | The same, through templates |

Destroying a template that contributed to a dataset leaves the dataset's hashes
but purges its materialized page images. The manifest entry becomes a tombstone
that says what was removed and when.

A deleted, cleared, or revoked source is excluded from every future dataset.
The next training run on the instance replaces the affected artifacts. Deletion
does not force an immediate retrain. Training is local, so the instance
operator can start one at any time.

## Dataset version, training run, and model artifact

These are contracts only. No tables exist until their issues begin.

**Dataset version:** an immutable manifest of annotation IDs, source hashes,
family-grouped splits, `schema_version`, `preprocessing_version`, the render
settings, the authorization scope, and a content hash. A split is assigned by
document family, so exact copies, revisions, and pages of one document can never
straddle train and evaluation.

**Training run:** the dataset hash, base model and its hash, code revision,
hyperparameters, seed, environment, metrics, and output artifact hash. It runs
on the instance, so BSF-100 must state the minimum hardware and must be safe to
run beside a serving instance, for example as a low-priority job.

**Model artifact:** a SHA-256, input signature, resolution, class list,
quantization, training run, gate report, license of the base weights, and status
(`candidate`, `pilot`, `active`, or `retired`). `detection_runs.model_sha256` is
the join key to this record, and it already works for the stock model, which
needs no registration to be recorded.

## Migration plan

1. BSF-96 adds `detection_runs`, `detection_run_pages`, and
   `detection_predictions` as additive tables on all supported databases.
   Provenance uses JSON text, not `jsonb`, because SQLite and MySQL are also
   supported.
2. No backfill. Existing templates have no predictions, which is correct:
   their fields read as unattributed, and they cannot be reused or trained on
   until someone reviews them.
3. `templates`, `template_versions`, and the fields API do not change.
4. Rollback drops the three tables. No authoring data is affected.

## Consequences

- Authoring remains the source of truth for documents, and provenance can be
  deleted without harm to any template.
- Storage grows with every detection, at roughly two rows per box. This is small
  next to the documents. Destroying templates or clearing provenance bounds it.
- A correction capture in BSF-97 has to diff against suggestions, because the
  builder saves whole field lists rather than change events.
- A merged field in `withDetectExistingFields` mode adds an area to an existing
  field and discards the suggestion's UUID, so that suggestion has no link. This
  mode is not enabled in this build.

## Alternatives considered

- **Store review state in `templates.fields`.** Rejected. It mixes authoring and
  training data, changes the API surface, and makes retention impossible.
- **Derive training data from saved templates.** Rejected. An unused blank is
  indistinguishable from a false detection, and field rectangles are input
  geometry rather than printed geometry.
- **One JSON document per run.** Rejected. Later milestones need to join on
  individual predictions.
- **A `prediction_id` key on streamed fields.** Rejected. Strong parameters
  would drop it on save, and the field `uuid` is already stable.
