{
  "subject": {{ toJson .Subject }},
  "keyUsage": ["certSign", "crlSign"],
  "extKeyUsage": ["serverAuth"],
  "basicConstraints": {"isCA": true, "maxPathLen": 0}
}
