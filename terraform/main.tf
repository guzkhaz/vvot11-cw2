terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }
  }
  required_version = ">= 0.13"
}

provider "yandex" {
  cloud_id  = var.cloud_id
  folder_id = var.folder_id
  zone      = var.zone
}

# Service Account

resource "yandex_iam_service_account" "sa" {
  name = "document-sa"
}

resource "yandex_iam_service_account_static_access_key" "sa_static_key" {
  service_account_id = yandex_iam_service_account.sa.id
}

resource "yandex_resourcemanager_folder_iam_member" "sa_keys" {
  folder_id = var.folder_id
  role      = "kms.keys.encrypterDecrypter"
  member    = "serviceAccount:${yandex_iam_service_account.sa.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "sa_viewer" {
  folder_id = var.folder_id
  role      = "lockbox.payloadViewer"
  member    = "serviceAccount:${yandex_iam_service_account.sa.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "sa_editor" {
  folder_id = var.folder_id
  role      = "ydb.editor"
  member    = "serviceAccount:${yandex_iam_service_account.sa.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "sa_uploader" {
  folder_id = var.folder_id
  role      = "storage.uploader"
  member    = "serviceAccount:${yandex_iam_service_account.sa.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "functions_functionInvoker" {
  folder_id = var.folder_id
  role      = "functions.functionInvoker"
  member    = "serviceAccount:${yandex_iam_service_account.sa.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "sa_admin" {
  folder_id = var.folder_id
  role      = "ymq.admin"
  member    = "serviceAccount:${yandex_iam_service_account.sa.id}"
}

# Keys

resource "yandex_lockbox_secret" "secret" {
  name = "documents-secret"
}

resource "yandex_lockbox_secret_version" "secret_version" {
  secret_id = yandex_lockbox_secret.secret.id

  entries {
    key        = "AWS_ACCESS_KEY_ID"
    text_value = yandex_iam_service_account_static_access_key.sa_static_key.access_key
  }

  entries {
    key        = "AWS_SECRET_ACCESS_KEY"
    text_value = yandex_iam_service_account_static_access_key.sa_static_key.secret_key
  }
}

# YDB

resource "yandex_ydb_database_serverless" "db" {
  name      = "documents-db"
  folder_id = var.folder_id
  serverless_database {
    storage_size_limit = 1
  }
}

resource "yandex_ydb_table" "docs-table" {
  path              = "docs"
  connection_string = yandex_ydb_database_serverless.db.ydb_full_endpoint

  column {
    name     = "id"
    type     = "Uuid"
    not_null = true
  }

  column {
    name     = "name"
    type     = "Utf8"
    not_null = true
  }

  column {
    name     = "url"
    type     = "Utf8"
    not_null = true
  }

  primary_key = ["id"]

  depends_on = [
    yandex_ydb_database_serverless.db,
    yandex_resourcemanager_folder_iam_member.sa_editor
  ]
}

# Bucket

resource "yandex_storage_bucket" "bucket" {
  bucket        = "bucket-${uuid()}"
  max_size      = 1e9
  folder_id     = var.folder_id
  force_destroy = true
}

# Queue

resource "yandex_message_queue" "upload_queue" {
  name                       = "documents-upload-queue"
  message_retention_seconds  = 900
  visibility_timeout_seconds = 300

  access_key = yandex_iam_service_account_static_access_key.sa_static_key.access_key
  secret_key = yandex_iam_service_account_static_access_key.sa_static_key.secret_key

  depends_on = [
    yandex_resourcemanager_folder_iam_member.sa_admin
  ]
}

data "yandex_message_queue" "upload_queue_data" {
  name       = yandex_message_queue.upload_queue.name
  access_key = yandex_iam_service_account_static_access_key.sa_static_key.access_key
  secret_key = yandex_iam_service_account_static_access_key.sa_static_key.secret_key

  depends_on = [yandex_message_queue.upload_queue]
}

# Functions

data "archive_file" "upload_function_zip" {
  type        = "zip"
  output_path = "${path.module}/upload_function.zip"
  source_dir  = "${path.module}/../src/upload"
}

resource "yandex_function" "upload_function" {
  name               = "upload-function"
  runtime            = "python312"
  entrypoint         = "main.handler"
  memory             = 1024
  execution_timeout  = 300
  service_account_id = yandex_iam_service_account.sa.id
  user_hash          = data.archive_file.upload_function_zip.output_sha256
  folder_id          = var.folder_id

  depends_on = [
    data.archive_file.upload_function_zip,
    yandex_lockbox_secret.secret,
    yandex_lockbox_secret_version.secret_version
  ]

  content {
    zip_filename = data.archive_file.upload_function_zip.output_path
  }

  environment = {
    YDB_ENDPOINT = "grpcs://${yandex_ydb_database_serverless.db.ydb_api_endpoint}"
    YDB_DATABASE = yandex_ydb_database_serverless.db.database_path
    BUCKET_NAME  = yandex_storage_bucket.bucket.bucket
    ZONE         = var.zone
  }

  secrets {
    id                   = yandex_lockbox_secret.secret.id
    version_id           = yandex_lockbox_secret_version.secret_version.id
    key                  = "AWS_ACCESS_KEY_ID"
    environment_variable = "AWS_ACCESS_KEY_ID"
  }

  secrets {
    id                   = yandex_lockbox_secret.secret.id
    version_id           = yandex_lockbox_secret_version.secret_version.id
    key                  = "AWS_SECRET_ACCESS_KEY"
    environment_variable = "AWS_SECRET_ACCESS_KEY"
  }
}

data "archive_file" "download_function_zip" {
  type        = "zip"
  output_path = "${path.module}/download_function.zip"
  source_dir  = "${path.module}/../src/download"
}

resource "yandex_function" "download_function" {
  name               = "download-function"
  runtime            = "python312"
  entrypoint         = "main.handler"
  memory             = 512
  execution_timeout  = 60
  service_account_id = yandex_iam_service_account.sa.id
  user_hash          = data.archive_file.download_function_zip.output_sha256
  folder_id          = var.folder_id

  depends_on = [data.archive_file.download_function_zip]

  content {
    zip_filename = data.archive_file.download_function_zip.output_path
  }

  environment = {
    YDB_ENDPOINT = "grpcs://${yandex_ydb_database_serverless.db.ydb_api_endpoint}"
    YDB_DATABASE = yandex_ydb_database_serverless.db.database_path
  }
}

# Trigger

resource "yandex_function_trigger" "upload_queue_trigger" {
  name      = "upload-queue-trigger"
  folder_id = var.folder_id

  message_queue {
    queue_id           = yandex_message_queue.upload_queue.arn
    service_account_id = yandex_iam_service_account.sa.id
    batch_size         = 1
    batch_cutoff       = 1
  }

  function {
    id                 = yandex_function.upload_function.id
    service_account_id = yandex_iam_service_account.sa.id
  }

  depends_on = [
    yandex_message_queue.upload_queue,
    yandex_function.upload_function
  ]
}

# API Gateway

data "template_file" "api_spec" {
  template = file("${path.module}/../openapi/spec.yaml")
  
  vars = {
    queue_url         = data.yandex_message_queue.upload_queue_data.url
    folder_id         = var.folder_id
    service_account_id = yandex_iam_service_account.sa.id
    function_id       = yandex_function.download_function.id
    bucket_name       = yandex_storage_bucket.bucket.bucket
  }
}

resource "yandex_api_gateway" "api" {
  name              = "documents-api"
  execution_timeout = "60"
  spec              = data.template_file.api_spec.rendered
}