# ---- One-time IAM survivor adoption (security account cold-start) ---------
variable "adopt_seeded_iam_roles" {
  description = "ONE-TIME security-account cold-start toggle. security/bootstrap is a brand new Terraform environment; the normal path creates the break-glass + CI IAM roles fresh via a first local apply under break-glass credentials. Set true ONLY if those three roles were instead hand-seeded (console/CLI) ahead of Terraform, so iam-survivor-import.tf ADOPTs the survivors into state instead of failing EntityAlreadyExists. Default false: the normal fresh-create path, so the import targets must not be generated. Remove the variable + iam-survivor-import.tf in a later cleanup PR once this account's bootstrap state is reconciled."
  type        = bool
  default     = false
}
