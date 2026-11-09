# Field detection baseline protocol

- Issue: BSF-95
- Contract: [ADR 0001](adr-0001-annotation-data-and-training-contracts.md)

This protocol measures the current detector and heuristics so a candidate model
can be compared against evidence. Numeric promotion targets come from a real
corpus run, and this document deliberately leaves them blank until then.

## Running it

```sh
bundle exec rake detection:baseline MANIFEST=corpus/manifest.json OUTPUT=reports/baseline.json
```

Run on documented deployment hardware, with nothing else using the CPU. Keep the
report, manifest, and source files together. Peak memory comes from `VmHWM`, so
it is only available on Linux, and it reports null elsewhere. Start a fresh
process for each run, because it is a process-lifetime peak.

## Corpus

Keep the corpus outside this repository. It contains documents that need
authorization, and nothing in it should ship with the application.

Every document needs a recorded authorization. Curate across:

- Document families, such as tax forms, leases, and onboarding packs.
- Languages. Cover at least those the type heuristics support: English, French,
  and German.
- Digital PDFs, scans, and images.
- Text fields, checkboxes, and signature areas.

Aim for at least 30 families and 300 reviewed pages for the first baseline, with
no family above 10% of pages. This size is a starting estimate, not a derived
requirement. Revisit it after looking at the confidence intervals.

## Manifest

```json
{
  "schema_version": 1,
  "name": "baseline-2026-11",
  "documents": [
    {
      "id": "lease-a-v1",
      "path": "files/lease-a-v1.pdf",
      "sha256": "<sha-256 of the file>",
      "family": "residential-lease",
      "split": "generalization",
      "source_kind": "digital_pdf",
      "language": "en",
      "authorization": "<reference to the permission for this document>",
      "pages": [
        {
          "page": 0,
          "review_state": "complete",
          "reviewer": "<reviewer>",
          "targets": [
            {
              "input": { "x": 0.1, "y": 0.2, "w": 0.3, "h": 0.04 },
              "blank": { "x": 0.1, "y": 0.235, "w": 0.3, "h": 0.005 },
              "localization_class": "text",
              "semantic_type": "signature",
              "disposition": "used"
            }
          ]
        }
      ]
    }
  ]
}
```

Geometry follows the coordinate contract in ADR 0001. `blank` is optional, and
metrics for `blank` cover only targets that provide it. `disposition` and
`review_state` have the meanings given in ADR 0001.

The manifest is rejected if a file's hash differs, a target is malformed, a
reviewer or authorization is missing, or a family or file hash appears in more
than one split.

## Splits

Assign splits by `family`, never by page or file. Exact copies, related
revisions, and every page of a document therefore stay together.

- `generalization`: families that represent unfamiliar forms. Hold these out
  from all future training.
- `repeated`: families expected to recur. A future training set may use these.

The report never combines the two, because repeated documents would flatter a
model and hide its behavior on unfamiliar forms. When exact reuse (BSF-98)
exists, report it as a third result rather than merging it into either split.

## Metrics

Each result is reported for two stages, two geometries, and two thresholds:

- Stage `suggestion` is the final output. Stage `detector` is model output at the
  operating threshold, before heuristics. Their difference is what the
  heuristics contribute.
- Geometry `input` is the usable rectangle. Geometry `blank` is the printed one.
- IoU thresholds of 0.5 and 0.75. Localization quality is the mean IoU of matches.

Matching is one-to-one, within a localization class, in descending confidence.

| Case | Treatment |
| --- | --- |
| Matched prediction | True positive |
| Unmatched `used` or `valid_unused` target | False negative |
| Unmatched prediction on a `complete` page | False positive |
| Unmatched prediction on a `partial` page | Not counted |
| Prediction mostly inside an `ignored` target | Not counted |
| Prediction on a `false_detection` target of a `complete` page | False positive |

Semantic accuracy is measured over matches whose target has a `semantic_type`.
It is the available measure until BSF-102 adds a dedicated stage.

Page latency is the gap between streamed pages, so it includes rendering,
inference, and heuristics. The first page also includes model load, so read p95
rather than max for a warmed process.

## Pilot protocol

The corpus measures boxes. The pilot measures the product goals, which are
manual corrections per reviewed page and time to finish field setup.

1. Choose at least 5 authors and 10 documents per author. None of the documents
   may have been set up before.
2. Give each document one condition: detection on, or manual setup. Balance the
   assignment, so no author sees one document in both conditions.
3. Time from the first builder interaction to the author declaring the fields
   complete. Exclude setup that is not about fields, such as naming signers.
4. Count additions, deletions, moves, resizes, and type changes per reviewed
   page. Until BSF-97 captures these, count them by comparing the suggestions in
   `detection_predictions` with the saved template fields.
5. Report medians and the spread per document family.

## Promotion targets

Fill these in from the first complete baseline report, before any candidate
model is selected. Do not change them after seeing a candidate's results.

| Measure | Baseline | Target |
| --- | --- | --- |
| Recall at IoU 0.5, `generalization`, `suggestion` | Pending corpus | Pending corpus |
| Precision at IoU 0.5, `generalization`, `suggestion` | Pending corpus | Pending corpus |
| Mean IoU, `generalization`, `suggestion` | Pending corpus | Pending corpus |
| Checkbox recall at IoU 0.5, `generalization` | Pending corpus | Pending corpus |
| Page latency p95 | Pending corpus | Pending corpus |
| Peak RSS | Pending corpus | Pending corpus |
| Corrections per reviewed page | Pending pilot | Pending pilot |
| Field setup time | Pending pilot | Pending pilot |
