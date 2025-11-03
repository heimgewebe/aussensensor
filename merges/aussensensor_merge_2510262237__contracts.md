### 📄 contracts/aussen.event.schema.json

**Größe:** 592 B | **md5:** `dcee2f38eef9973cfee5f4b930517d74`

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "aussensensor/weltgewebe event",
  "type": "object",
  "required": ["ts", "type", "source", "title"],
  "properties": {
    "ts": { "type": "string", "format": "date-time" },
    "type": { "type": "string", "enum": ["news", "sensor", "project", "alert"] },
    "source": { "type": "string" },
    "title": { "type": "string" },
    "summary": { "type": "string", "maxLength": 500 },
    "url": { "type": "string" },
    "tags": { "type": "array", "items": { "type": "string" } }
  },
  "additionalProperties": false
}
```

