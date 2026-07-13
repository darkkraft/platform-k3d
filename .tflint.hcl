# tflint — enforces the variable/style contract the tree is written to:
# every variable typed + described, no undocumented outputs, no unused
# declarations, snake_case naming, required_version + required_providers pinned
# in every root and module. CI runs this hard (no || true); pre-commit mirrors it.
tflint {
  required_version = ">= 0.50"
}

plugin "terraform" {
  enabled = true
  preset  = "all"
}
