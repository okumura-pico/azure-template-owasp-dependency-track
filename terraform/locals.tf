locals {
  pgsql_version              = "17"
  pgsql_storage_mb           = "32768"
  image_registry             = "docker.io"
  dtrack_apiserver_image_tag = "dependencytrack/apiserver:latest"
  dtrack_frontend_image_tag  = "dependencytrack/frontend:latest"

  # 予算
  budget_amount = 7000

  now = timestamp()
  # 次の日本時間8:50
  today_2350_utc = "${formatdate("YYYY-MM-DD", local.now)}T23:50:00Z"
  next_0850      = timecmp(local.now, local.today_2350_utc) < 0 ? local.today_2350_utc : timeadd(local.today_2350_utc, "24h")
  # 次の日本時間18:50
  today_0950_utc = "${formatdate("YYYY-MM-DD", local.now)}T09:50:00Z"
  next_1850      = timecmp(local.now, local.today_0950_utc) < 0 ? local.today_0950_utc : timeadd(local.today_0950_utc, "24h")
}
