---
meeting_ref: "acmemeet:https://meet.acme.example/rec/share/abc?token=SAMPLE-SECRET"
---

Refused on purpose: a share URL with a token — committed refs must never carry URLs or
credentials, so this exits 4 with reason refused-credential.
