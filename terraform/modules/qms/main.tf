/*
Copyright 2022 Google LLC

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
*/

terraform {
  provider_meta "google" {
    module_name = "cloud-solutions/quota-monitoring-solution-deploy-v5.1" #x-release-please-minor
  }
}

locals {
  expanded_region    = var.region == "us-central" || var.region == "europe-west" ? "${var.region}1" : var.region
  use_github_release = var.qms_version != "main" ? true : false
}

data "google_project" "project" {
  project_id = var.project_id
}


# Enable Cloud Resource Manager API
module "project-service-cloudresourcemanager" {
  source  = "terraform-google-modules/project-factory/google//modules/project_services"
  version = "4.0.0"

  project_id = var.project_id

  activate_apis = [
    "cloudresourcemanager.googleapis.com"
  ]
}

# Enable APIs
module "project-services" {
  source  = "terraform-google-modules/project-factory/google//modules/project_services"
  version = "4.0.0"

  project_id = var.project_id

  activate_apis = [
    "compute.googleapis.com",
    "iam.googleapis.com",
    "monitoring.googleapis.com",
    "storage.googleapis.com",
    "storage-api.googleapis.com",
    "bigquery.googleapis.com",
    "pubsub.googleapis.com",
    "appengine.googleapis.com",
    "cloudscheduler.googleapis.com",
    "cloudfunctions.googleapis.com",
    "cloudbuild.googleapis.com",
    "bigquerydatatransfer.googleapis.com",
    "run.googleapis.com",
    "eventarc.googleapis.com",
    "artifactregistry.googleapis.com"
  ]
  depends_on = [module.project-service-cloudresourcemanager]
}

# Create Pub/Sub topic to list projects in the parent node
resource "google_pubsub_topic" "topic_alert_project_id" {
  name       = var.topic_alert_project_id
  depends_on = [module.project-services]
}

# Create Pub/Sub topic to send notification
resource "google_pubsub_topic" "topic_alert_notification" {
  name       = var.topic_alert_notification
  depends_on = [module.project-services]
}

# Cloud scheduler job to invoke list projects cloud function
resource "google_cloud_scheduler_job" "job" {
  name             = var.scheduler_cron_job_name
  description      = var.scheduler_cron_job_description
  schedule         = var.scheduler_cron_job_frequency
  time_zone        = var.scheduler_cron_job_timezone
  attempt_deadline = var.scheduler_cron_job_deadline
  region           = local.expanded_region
  depends_on       = [module.project-services]
  retry_config {
    retry_count = 1
  }

  http_target {
    http_method = "POST"
    uri         = google_cloudfunctions2_function.function-listProjects.service_config[0].uri
    body        = base64encode(jsonencode({
      organizations = var.organizations
      threshold     = var.threshold
      projectId     = var.project_id
    }))

    oidc_token {
      service_account_email = var.service_account_email
    }
  }
}

# Cloud scheduler job to invoke config app alert cloud function
resource "google_cloud_scheduler_job" "app_alert_configure_job" {
  name             = var.scheduler_app_alert_config_job_name
  description      = var.scheduler_app_alert_job_description
  schedule         = var.scheduler_app_alert_job_frequency
  time_zone        = var.scheduler_cron_job_timezone
  attempt_deadline = var.scheduler_cron_job_deadline
  region           = local.expanded_region
  depends_on       = [module.project-services]
  retry_config {
    retry_count = 1
  }

  http_target {
    http_method = "POST"
    uri         = google_cloudfunctions2_function.function-configureAppAlert.service_config[0].uri

    oidc_token {
      service_account_email = var.service_account_email
    }
  }
}

resource "google_storage_bucket" "bucket_gcf_source" {
  name          = "${var.project_id}-gcf-source"
  storage_class = "REGIONAL"
  location      = local.expanded_region
  force_destroy = "true"
  uniform_bucket_level_access = "true"
}

data "archive_file" "local_source_code_zip" {
  count = local.use_github_release ? 0 : 1

  type        = "zip"
  source_dir  = abspath("${path.module}/../../../quota-scan")
  output_path = var.source_code_zip
}

resource "null_resource" "source_code_zip" {
  count = local.use_github_release ? 1 : 0

  triggers = {
    on_version_change = var.qms_version
  }

  provisioner "local-exec" {
    command = "curl -Lo ${var.source_code_zip} ${var.source_code_base_url}/${var.qms_version}/${var.source_code_zip}"
  }
}

resource "google_storage_bucket_object" "source_code_object" {
  name   = "${var.qms_version}-${var.source_code_zip}"
  bucket = google_storage_bucket.bucket_gcf_source.name
  source = var.source_code_zip

  depends_on = [
    null_resource.source_code_zip,
    data.archive_file.local_source_code_zip
  ]
}

# cloud function to list projects
resource "google_cloudfunctions2_function" "function-listProjects" {
  name        = var.cloud_function_list_project
  location    = local.expanded_region
  description = var.cloud_function_list_project_desc
  depends_on  = [module.project-services]

  build_config {
    runtime     = "java17"
    entry_point = "functions.ListProjects"
    source {
      storage_source {
        bucket = google_storage_bucket.bucket_gcf_source.name
        object = google_storage_bucket_object.source_code_object.name
      }
    }
  }

  service_config {
    max_instance_count    = 100
    available_memory      = "${var.cloud_function_list_project_memory}Mi"
    timeout_seconds       = var.cloud_function_list_project_timeout
    service_account_email = var.service_account_email
    environment_variables = {
      PUBLISH_TOPIC = google_pubsub_topic.topic_alert_project_id.name
      HOME_PROJECT  = var.project_id
    }
  }
}

# IAM entry for all users to invoke the function
resource "google_cloudfunctions2_function_iam_member" "invoker-listProjects" {
  project        = google_cloudfunctions2_function.function-listProjects.project
  location       = google_cloudfunctions2_function.function-listProjects.location
  cloud_function = google_cloudfunctions2_function.function-listProjects.name
  depends_on     = [module.project-services]

  role   = "roles/cloudfunctions.invoker"
  member = "serviceAccount:${var.service_account_email}"
}

# Second cloud function to scan project
resource "google_cloudfunctions2_function" "function-scanProject" {
  name        = var.cloud_function_scan_project
  location    = local.expanded_region
  description = var.cloud_function_scan_project_desc
  depends_on  = [module.project-services]

  build_config {
    runtime     = "java17"
    entry_point = "functions.ScanProjectQuotas"
    source {
      storage_source {
        bucket = google_storage_bucket.bucket_gcf_source.name
        object = google_storage_bucket_object.source_code_object.name
      }
    }
  }

  service_config {
    max_instance_count    = 100
    available_memory      = "${var.cloud_function_scan_project_memory}Mi"
    timeout_seconds       = var.cloud_function_scan_project_timeout
    service_account_email = var.service_account_email
    environment_variables = {
      NOTIFICATION_TOPIC = google_pubsub_topic.topic_alert_notification.name
      THRESHOLD          = var.threshold
      BIG_QUERY_DATASET  = var.big_query_dataset_id
      BIG_QUERY_TABLE    = var.big_query_table_id
    }
  }

  event_trigger {
    trigger_region = local.expanded_region
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = google_pubsub_topic.topic_alert_project_id.id
  }
}

# IAM entry for all users to invoke the function
resource "google_cloudfunctions2_function_iam_member" "invoker-scanProject" {
  project        = google_cloudfunctions2_function.function-scanProject.project
  location       = google_cloudfunctions2_function.function-scanProject.location
  cloud_function = google_cloudfunctions2_function.function-scanProject.name
  depends_on     = [module.project-services]

  role   = "roles/cloudfunctions.invoker"
  member = "serviceAccount:${var.service_account_email}"
}

data "archive_file" "local_source_code_notification_zip" {
  count = local.use_github_release ? 0 : 1

  type        = "zip"
  source_dir  = abspath("${path.module}/../../../quota-notification")
  output_path = "./${var.source_code_notification_zip}"
}

resource "null_resource" "source_code_notification_zip" {
  count = local.use_github_release ? 1 : 0

  triggers = {
    on_version_change = var.qms_version
  }

  provisioner "local-exec" {
    command = "curl -Lo ${var.source_code_notification_zip} ${var.source_code_base_url}/${var.qms_version}/${var.source_code_notification_zip}"
  }
}

resource "google_storage_bucket_object" "source_code_notification_object" {
  name   = "${var.qms_version}-${var.source_code_notification_zip}"
  bucket = google_storage_bucket.bucket_gcf_source.name
  source = var.source_code_notification_zip

  depends_on = [
    null_resource.source_code_notification_zip,
    data.archive_file.local_source_code_notification_zip
  ]
}

# Third cloud function to send notification
resource "google_cloudfunctions2_function" "function-notificationProject" {
  name        = var.cloud_function_notification_project
  location    = local.expanded_region
  description = var.cloud_function_notification_project_desc
  depends_on  = [module.project-services]

  build_config {
    runtime     = "java17"
    entry_point = "functions.SendNotification"
    source {
      storage_source {
        bucket = google_storage_bucket.bucket_gcf_source.name
        object = google_storage_bucket_object.source_code_notification_object.name
      }
    }
  }

  service_config {
    max_instance_count    = 100
    available_memory      = "${var.cloud_function_notification_project_memory}Mi"
    timeout_seconds       = var.cloud_function_notification_project_timeout
    service_account_email = var.service_account_email
    environment_variables = {
      HOME_PROJECT  = var.project_id
      ALERT_DATASET = var.big_query_alert_dataset_id
      ALERT_TABLE   = var.big_query_alert_table_id
      APP_ALERT_DATASET = var.big_query_alert_dataset_id
      APP_ALERT_TABLE   = var.big_query_app_alert_table_id
    }
  }

  event_trigger {
    trigger_region = local.expanded_region
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = google_pubsub_topic.topic_alert_notification.id
  }
}

# IAM entry for all users to invoke the function
resource "google_cloudfunctions2_function_iam_member" "invoker-notificationProject" {
  project        = google_cloudfunctions2_function.function-notificationProject.project
  location       = google_cloudfunctions2_function.function-notificationProject.location
  cloud_function = google_cloudfunctions2_function.function-notificationProject.name
  depends_on     = [module.project-services]

  role   = "roles/cloudfunctions.invoker"
  member = "serviceAccount:${var.service_account_email}"
}

# cloud function to configure app alerting
resource "google_cloudfunctions2_function" "function-configureAppAlert" {
  name        = var.cloud_function_config_app_alert
  location    = local.expanded_region
  description = var.cloud_function_config_app_alert_desc
  depends_on  = [module.project-services]

  build_config {
    runtime     = "java17"
    entry_point = "functions.ConfigureAppAlert"
    source {
      storage_source {
        bucket = google_storage_bucket.bucket_gcf_source.name
        object = google_storage_bucket_object.source_code_notification_object.name
      }
    }
  }

  service_config {
    max_instance_count    = 100
    available_memory      = "${var.cloud_function_config_app_alert_memory}Mi"
    timeout_seconds       = var.cloud_function_config_app_alert_timeout
    service_account_email = var.service_account_email
    environment_variables = {
      HOME_PROJECT  = var.project_id
      APP_ALERT_DATASET = var.big_query_alert_dataset_id
      APP_ALERT_TABLE   = var.big_query_app_alert_table_id
      CSV_SOURCE_URI = "gs://${google_storage_bucket.bucket_gcf_source.name}/${var.app_alert_csv_file_name}"
    }
  }
}

# IAM entry for all users to invoke the function
resource "google_cloudfunctions2_function_iam_member" "invoker-configureAppAlert" {
  project        = google_cloudfunctions2_function.function-configureAppAlert.project
  location       = google_cloudfunctions2_function.function-configureAppAlert.location
  cloud_function = google_cloudfunctions2_function.function-configureAppAlert.name
  depends_on     = [module.project-services]

  role   = "roles/cloudfunctions.invoker"
  member = "serviceAccount:${var.service_account_email}"
}

# BigQuery Dataset
resource "google_bigquery_dataset" "dataset" {
  dataset_id                      = var.big_query_dataset_id
  friendly_name                   = var.big_query_dataset_id
  description                     = var.big_query_dataset_desc
  location                        = var.big_query_dataset_location
  default_partition_expiration_ms = var.big_query_dataset_default_partition_expiration_ms
  depends_on                      = [module.project-services]
}

# BigQuery Table
resource "google_bigquery_table" "default" {
  dataset_id = google_bigquery_dataset.dataset.dataset_id
  table_id   = var.big_query_table_id

  time_partitioning {
    type = var.big_query_table_partition
  }

  labels = {
    env = "default"
  }

  schema = <<EOF
[
  {
    "name": "project_id",
    "type": "STRING",
    "mode": "NULLABLE",
    "description": "Project Id the quota metric applies to"
  },
  {
    "name": "added_at",
    "type": "TIMESTAMP",
    "mode": "NULLABLE",
    "description": "Time at which the quota data was retrieved"
  },
  {
    "name": "region",
    "type": "STRING",
    "mode": "NULLABLE",
    "description": "Region the quota metric applies to"
  },
  {
    "name": "quota_metric",
    "type": "STRING",
    "mode": "NULLABLE",
    "description": "Quota metric"
  },
  {
    "name": "api_method",
    "type": "STRING",
    "mode": "NULLABLE",
    "description": "Name of the api being used, only applicable to rate quotas."
  },
  {
    "name": "limit_name",
    "type": "STRING",
    "mode": "NULLABLE",
    "description": "Name of the limit"
  },
  {
    "name": "quota_type",
    "type": "STRING",
    "mode": "NULLABLE",
    "description": "The type of quota, ALLOCATION or RATE"
  },
  {
    "name": "current_usage",
    "type": "INT64",
    "mode": "NULLABLE",
    "description": "Current usage against the quota"
  },
  {
    "name": "max_usage",
    "type": "INT64",
    "mode": "NULLABLE",
    "description": "Maximum usage against the quota in the query window"
  },
  {
    "name": "quota_limit",
    "type": "INT64",
    "mode": "NULLABLE",
    "description": "Quota limit for the metric"
  },
  {
    "name": "threshold",
    "type": "INT64",
    "mode": "NULLABLE",
    "description": "Alerting threshold for the quota metric"
  }
]
EOF

}

#Schedule Query to get Alerts data
resource "google_bigquery_data_transfer_config" "query_config" {
  display_name              = var.bigquery_data_transfer_query_name
  location                  = var.big_query_dataset_location
  data_source_id            = "scheduled_query"
  schedule                  = var.Alert_data_scanning_frequency
  notification_pubsub_topic = google_pubsub_topic.topic_alert_notification.id
  destination_dataset_id    = google_bigquery_dataset.quota_usage_alert_dataset.dataset_id
  service_account_name      = var.service_account_email
  depends_on                = [module.project-services]
  params = {
    destination_table_name_template = var.big_query_alert_table_id
    write_disposition               = "WRITE_TRUNCATE"
    query                           = "SELECT quota_metric, current_usage, max_usage, quota_limit, current_consumption, max_consumption, project_id, region, MAX(added_at) FROM ( SELECT project_id, region, quota_metric, added_at, quota_limit, current_usage, max_usage, ROUND( ( SAFE_DIVIDE( CAST(current_usage AS BIGNUMERIC), CAST(quota_limit AS BIGNUMERIC) ) * 100 ), 2 ) AS current_consumption, ROUND( ( SAFE_DIVIDE( CAST(max_usage AS BIGNUMERIC), CAST(quota_limit AS BIGNUMERIC) ) * 100 ), 2 ) AS max_consumption, threshold FROM `${var.project_id}.${google_bigquery_dataset.dataset.dataset_id}.${google_bigquery_table.default.table_id}` ) c WHERE c.current_consumption >= c.threshold OR c.max_consumption >= c.threshold GROUP BY quota_metric, current_usage, max_usage, quota_limit, current_consumption, max_consumption, project_id, region"
  }
}

#Bigquery Alert Dataset
resource "google_bigquery_dataset" "quota_usage_alert_dataset" {
  dataset_id    = var.big_query_alert_dataset_id
  friendly_name = "quota_usage_alert_dataset"
  description   = var.big_query_alert_dataset_desc
  location      = var.big_query_dataset_location
  depends_on    = [module.project-services]
}

# BigQuery Table for decentralize (App) alerting
resource "google_bigquery_table" "quota_monitoring_app_alerting_table" {
  dataset_id = var.big_query_alert_dataset_id
  table_id   = var.big_query_app_alert_table_id

  time_partitioning {
    type = var.big_query_table_partition
  }

  labels = {
    env = "default"
  }

  schema = <<EOF
[
  {
    "name": "project_id",
    "type": "STRING",
    "mode": "NULLABLE",
    "description": "project id"
  },
  {
    "name": "email_id",
    "type": "STRING",
    "mode": "NULLABLE",
    "description": "email id"
  },
  {
    "name": "app_code",
    "type": "STRING",
    "mode": "NULLABLE",
    "description": "application code - by default incremental numbers"
  },
  {
    "name": "dashboard_url",
    "type": "STRING",
    "mode": "NULLABLE",
    "description": "dashboard url"
  },
  {
    "name": "custom_log_metric_id",
    "type": "STRING",
    "mode": "NULLABLE",
    "description": "custom log metric id"
  },
  {
    "name": "notification_channel_id",
    "type": "STRING",
    "mode": "NULLABLE",
    "description": "notification channel id"
  },
  {
    "name": "alert_policy_id",
    "type": "STRING",
    "mode": "NULLABLE",
    "description": "alert policy id"
  }
]
EOF

}



# Custom log-based metric to send quota alert data through
resource "google_logging_metric" "quota_logging_metric" {
  name        = "resource_usage"
  description = "Tracks logs for quota usage above threshold"
  filter      = "logName:\"projects/${var.project_id}/logs/\" jsonPayload.message:\"ProjectId | Scope |\""
  depends_on  = [module.project-services]
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
    labels {
      key        = "data"
      value_type = "STRING"
    }
  }
  label_extractors = {
    "data" = "EXTRACT(jsonPayload.message)"
  }
}

#Set notification channels below
#Add Notification channel - Email
resource "google_monitoring_notification_channel" "email0" {
  display_name = "Oncall"
  type         = "email"
  depends_on   = [module.project-services]
  labels = {
    email_address = var.notification_email_address
  }
}

#Add Notification channel - PagerDuty - supply service_key token
#resource "google_monitoring_notification_channel" "pagerDuty" {
#  display_name = "PagerDuty Services"
#  type         = "pagerduty"
#  labels = {
#    "channel_name" = "#foobar"
#  }
#  sensitive_labels {
#    service_key = "one"
#  }
#}

#Log sink to route logs to log bucket
resource "google_logging_project_sink" "instance-sink" {
  name                   = var.log_sink_name
  description            = "Log sink to route logs sent by the Notification cloud function to the designated log bucket"
  destination            = "logging.googleapis.com/projects/${var.project_id}/locations/global/buckets/${var.alert_log_bucket_name}"
  filter                 = "logName=\"projects/${var.project_id}/logs/quota-alerts\""
  unique_writer_identity = true
  depends_on             = [module.project-services]
}

resource "null_resource" "update_logging_sink" {
  triggers = {
    always_run = "${timestamp()}"
  }
  depends_on     = [module.project-services]
#   triggers = {
#     on_version_change = var.qms_version
#   }

  provisioner "local-exec" {
    command = "gcloud logging sinks update _Default --log-filter=\"NOT (severity=DEFAULT OR severity=DEBUG AND resource.labels.function_name=quotaMonitoringListProjects) AND NOT (severity=DEFAULT OR severity=DEBUG AND resource.labels.function_name=quotaMonitoringScanProjects) AND NOT (severity=DEFAULT OR severity=DEBUG AND resource.labels.function_name=configAppAlerts) AND NOT (severity=DEFAULT OR severity=DEBUG AND resource.labels.function_name=quotaMonitoringNotification)\""
  }
}

#Because our sink uses a unique_writer, we must grant that writer access to the bucket.
resource "google_project_iam_binding" "log-writer" {
  project    = var.project_id
  role       = "roles/logging.configWriter"
  depends_on = [module.project-services]
  members = [
    "serviceAccount:${var.service_account_email}",
  ]
}

#Log bucket to store logs
resource "google_logging_project_bucket_config" "logging_bucket" {
  project        = var.project_id
  location       = "global"
  retention_days = var.retention_days
  bucket_id      = var.alert_log_bucket_name
  description    = "Log bucket to store logs related to quota alerts sent by the Notification cloud function"
  depends_on     = [module.project-services]
}

#Alert policy for log-based metric
# Condition display name can be changed based on user's quota range
resource "google_monitoring_alert_policy" "alert_policy_quota" {
  display_name = "Resources reaching Quotas"
  combiner     = "OR"
  conditions {
    display_name = "Resources reaching Quotas"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.quota_logging_metric.name}\"  AND resource.type=\"cloud_function\""
      duration        = "60s"
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      trigger {
        count = 1
      }
      aggregations {
        per_series_aligner = "ALIGN_COUNT"
        alignment_period   = "60s"
      }
    }
  }
  documentation {
    mime_type = "text/markdown"
    content   = "$${metric.label.data}"
  }
  notification_channels = [
    google_monitoring_notification_channel.email0.name
  ]
  depends_on = [
    module.project-services,
    google_logging_metric.quota_logging_metric
  ]
}

# Revert allowed ingress settings Org Policy for Cloud Functions if requested
resource "google_project_organization_policy" "ingress_policy_override" {
  count      = var.revert_org_policies ? 1 : 0
  project    = var.project_id
  constraint = "constraints/cloudfunctions.allowedIngressSettings"

  restore_policy {
    default = true
  }
}

# Support Cloud Functions 2nd Gen Cloud Build SA acting as the custom runtime service account
resource "google_service_account_iam_member" "cloudbuild_sa_user" {
  service_account_id = "projects/${var.project_id}/serviceAccounts/${var.service_account_email}"
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${data.google_project.project.number}@cloudbuild.gserviceaccount.com"
}

resource "google_service_account_iam_member" "compute_sa_user" {
  service_account_id = "projects/${var.project_id}/serviceAccounts/${var.service_account_email}"
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${data.google_project.project.number}-compute@developer.gserviceaccount.com"
}

# Grant project-level roles to Cloud Build Service Account to enable image upload and log writing
resource "google_project_iam_member" "cloudbuild_artifact_writer" {
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${data.google_project.project.number}@cloudbuild.gserviceaccount.com"
}

resource "google_project_iam_member" "compute_artifact_writer" {
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${data.google_project.project.number}-compute@developer.gserviceaccount.com"
}

resource "google_project_iam_member" "cloudbuild_storage_viewer" {
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${data.google_project.project.number}@cloudbuild.gserviceaccount.com"
}

resource "google_project_iam_member" "compute_storage_viewer" {
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${data.google_project.project.number}-compute@developer.gserviceaccount.com"
}

resource "google_project_iam_member" "cloudbuild_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${data.google_project.project.number}@cloudbuild.gserviceaccount.com"
}

resource "google_project_iam_member" "compute_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${data.google_project.project.number}-compute@developer.gserviceaccount.com"
}

resource "google_project_iam_member" "cloudbuild_service_agent" {
  project = var.project_id
  role    = "roles/cloudbuild.serviceAgent"
  member  = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-cloudbuild.iam.gserviceaccount.com"
}



