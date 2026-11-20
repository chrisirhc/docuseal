# fieldlab: an external detector and a feedback loop

- Contract: [ADR 0001](adr-0001-annotation-data-and-training-contracts.md)
- Code: `lib/fieldlab.rb`, `lib/templates/detect_fields_remote.rb`,
  `app/jobs/send_fieldlab_template_job.rb`, `app/jobs/send_fieldlab_detected_job.rb`

fieldlab is a separate service for comparing and tuning field detection methods. This app
can use it as its detector and feed it what authors do, with no extra step for the author.
fieldlab is where the methods are configured, inspected, debugged, trained and tuned.

## Turning it on

| Variable | Meaning |
| --- | --- |
| `FIELDLAB_URL` | Base URL of the fieldlab server, such as `http://host.docker.internal:8765`. Unset: nothing below happens |
| `FIELDLAB_INSTANCE` | The name of this app in fieldlab. Defaults to `HOST` |

## What happens

1. **Detect fields.** The builder's button sends each page's document to
   `POST /api/detect` and streams fieldlab's fields in the usual shape. If fieldlab cannot
   be reached before the first page, the built-in detector answers instead. fieldlab can
   also answer `use_builtin`, when its page is set to let this app's detector answer. In
   both cases the built-in detector's fields are then sent to `POST /api/docuseal/detected`
   by `SendFieldlabDetectedJob` (best effort, like the save below), so fieldlab can score
   both detectors on the same documents. Each request logs which detector answered, as
   `fieldlab: Detect fields on template N answered by fieldlab` or `... uses the built-in
   detector: <reason>`.
2. **Save.** Each save of a template, from the builder or the API, queues
   `SendFieldlabTemplateJob`. It posts the template's fields to
   `POST /api/docuseal/events`. fieldlab names any document it does not hold, the job
   uploads those to `POST /api/docuseal/documents`, and it posts the template again.
   The job is best effort: a failure is logged and never retried or shown to the author.
3. **In fieldlab.** The document becomes a lab document, the detection becomes a scored
   run, and the saved fields become its labels. When the same file is uploaded again
   under another template, fieldlab answers with the saved layout instead of a new guess.

## Provenance

Detection runs are recorded as before (BSF-96), with these differences for a fieldlab run:

- `model_version` is the detector's name, such as `fieldlab/hybrid` or `fieldlab/memory`,
  and `model_sha256` is the hash fieldlab reports for its method and parameters.
- `parameters` holds `detector: "fieldlab"` and the method.
- A `detector` prediction is fieldlab's box with the class its detector gave it. The
  `suggestion` is the same box with its final type. No page heuristic of this app runs.

## Where this departs from ADR 0001

Read these before turning it on outside development.

- **Data leaves the instance.** The ADR decided that no data leaves the instance. fieldlab
  itself can run on the same host, but its default method sends page images to the hosted
  Jev API. Use a local method in fieldlab, or keep `FIELDLAB_URL` unset, for documents that
  must stay.
- **A saved template is treated as truth.** The ADR says a correction is evidence and
  enters training only through a reviewed annotation (BSF-97). fieldlab takes every saved
  template as the complete labels of its document, including a half-finished one.
- **Capture settings cover saves only.** An account that turned off provenance capture sends
  no saved template, but "Detect fields" still sends the document to fieldlab.
- **Reuse is by exact file match.** That is BSF-98 done outside the app, without the
  confirmation step that issue describes.

## Development

The devcontainer sets `FIELDLAB_URL` to the host's port 8765. Start fieldlab there with
`uv run fieldlab label`, or start the container with `FIELDLAB_URL=` to use the built-in
detector.
