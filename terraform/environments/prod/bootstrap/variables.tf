# ---- One-time IAM survivor adoption (prod cold-start) ----------------------
variable "adopt_seeded_iam_roles" {
  description = "ONE-TIME prod cold-start toggle. The prod account had its bootstrap state cleared, but the break-glass + CI IAM roles this layer manages still exist as live AWS resources. Set true ONLY for the prod cold-start apply so iam-survivor-import.tf ADOPTs the survivors into state instead of failing EntityAlreadyExists. Default false: a fresh account has no survivors, so the import targets must not be generated. Remove the variable + iam-survivor-import.tf in a later cleanup PR once prod state is reconciled."
  type        = bool
  default     = false
}
