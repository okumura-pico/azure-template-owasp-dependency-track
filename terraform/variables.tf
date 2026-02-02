variable "subscription_id" {
  type = string
}
variable "prefix" {
  type        = string
  description = "リソース名のプレフィックス"
}
variable "location" {
  type        = string
  description = "リージョン"
}
variable "pgsql_login" {
  type        = string
  description = "PostgreSQL administrator ログインID"
  default     = "postgres"
}
variable "pgsql_password" {
  type        = string
  description = "PostgreSQL administrator パスワード"
}
variable "pgsql_sku_name" {
  type    = string
  default = "B_Standard_B2ms"
}
