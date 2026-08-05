# Folders, Groupings, Order, and Sort

These properties are all set on the table element alongside `columns` and `metrics`.

## Folders

Group columns into visual folders using the `folders` array. Reference the folder `id` in the `order` array to position the folder in the column list.

```json
"folders": [
  {
    "id": "folder-dates",
    "name": "Date Fields",
    "items": [
      "<col-id-order-date>",
      "<col-id-ship-date>"
    ]
  },
  {
    "id": "folder-financials",
    "name": "Financials",
    "items": [
      "<col-id-price>",
      "<col-id-cost>",
      "col-profit"
    ]
  }
]
```

**Folder schema:** `id` (required), `name` (required), `items`? (array of column IDs and/or nested folder IDs)

## Groupings

Groupings define default group-by behavior on the table element.

```json
"groupings": [
  {
    "id": "grouping-1",
    "groupBy": [
      "<column-id>"
    ],
    "calculations": [
      "<calculation-column-id>"
    ]
  }
]
```

**Grouping schema:** `id` (required), `groupBy`? (array of column or folder IDs), `calculations`? (array of calculation column IDs)

### Multiple levels — each id appears at most ONCE across all levels

Levels nest hierarchically by array order (outer → inner). Sigma collapses every
level's `groupBy` into a single flat `GROUP BY` at the warehouse (it does not run a
separate grouping step per level) and assembles the full combined key automatically.

**The hard rule (POST-enforced, live-verified): no column or calculation id may
appear more than once across the whole `groupings` array — in either `groupBy` OR
`calculations`.** Repeating any id fails the POST with
**`Duplicate column or folder reference: '<id>'`**. So:

- Each level's `groupBy` lists only the NEW dimension it adds (never repeat a parent
  level's dimension).
- Each aggregate in `calculations` is listed on exactly ONE level — typically the
  innermost — NOT repeated per level. Sigma still applies it across the collapsed
  `GROUP BY`.

✅ **Correct** — dimensions incremental, the calculation listed once (inner level):

```json
"groupings": [
  { "id": "by-region", "groupBy": ["col-region"] },
  { "id": "by-flag",   "groupBy": ["col-flag"], "calculations": ["col-total"] }
]
```

(Listing `calculations` on the outer level instead, or omitting it, also POSTs clean —
just don't list the same calc on more than one level.)

❌ **Wrong — inner level repeats the outer dimension** → `Duplicate column or folder reference: 'col-region'`:

```json
"groupings": [
  { "id": "by-region", "groupBy": ["col-region"] },
  { "id": "by-flag",   "groupBy": ["col-region", "col-flag"] }
]
```

❌ **Also wrong — the same calculation repeated on every level** → `Duplicate column or folder reference: 'col-total'`:

```json
"groupings": [
  { "id": "by-region", "groupBy": ["col-region"], "calculations": ["col-total"] },
  { "id": "by-flag",   "groupBy": ["col-flag"],   "calculations": ["col-total"] }
]
```

## Column order

The `order` array sets the display sequence of columns and folders. Items not listed appear after the listed ones. Summary columns are excluded from `order`.

```json
"order": [
  "folder-dates",
  "<col-id-1>",
  "<col-id-2>",
  "folder-financials"
]
```

## Sort

The `sort` array sets the default sort order on the table element.

```json
"sort": [
  {
    "columnId": "<col-id>",
    "direction": "descending",
    "nulls": "last"
  }
]
```

**`direction` values:** `"ascending"`, `"descending"`

**`nulls` values:** `"first"`, `"last"`, `"connection-default"`
