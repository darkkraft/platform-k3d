include "root" {
  path = find_in_parent_folders()
}

include "common" {
  path           = "${get_repo_root()}/stages/_common/services.hcl"
  merge_strategy = "deep"
}
