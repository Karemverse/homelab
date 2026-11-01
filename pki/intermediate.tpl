{
  "subject": {{ toJson .Subject }},
  "keyUsage": ["certSign", "crlSign"],
  "extKeyUsage": ["serverAuth"],
  "basicConstraints": {"isCA": true, "maxPathLen": 0},
  "nameConstraints": {
    "critical": true,
    "permittedDNSDomains": ["homelab.internal"],
    "excludedIPRanges": ["0.0.0.0/0", "::/0"]
  }
}
