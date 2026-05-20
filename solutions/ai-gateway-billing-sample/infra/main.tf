data "azurerm_client_config" "current" {}

resource "random_pet" "suffix" {
  length    = 1
  separator = ""
}

locals {
  suffix                = random_pet.suffix.id
  name                  = "${var.name_prefix}${local.suffix}"
  foundry_account_name  = "fndry-${local.name}"
  foundry_resource_id   = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/rg-${local.name}/providers/Microsoft.CognitiveServices/accounts/${local.foundry_account_name}"
}

# =============================================================================
# Resource Group
# =============================================================================

resource "azurerm_resource_group" "this" {
  name     = "rg-${local.name}"
  location = var.location
  tags     = var.tags
}

# =============================================================================
# Monitoring — Log Analytics + Application Insights
# =============================================================================

resource "azurerm_log_analytics_workspace" "this" {
  name                = "law-${local.name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

resource "azurerm_application_insights" "this" {
  name                = "appi-${local.name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  workspace_id        = azurerm_log_analytics_workspace.this.id
  application_type    = "web"
  tags                = var.tags
}

# Enable custom metrics with dimensions (required for llm-emit-token-metric).
# Uses ARM PATCH via Azure CLI because azapi_update_resource does not persist
# this property reliably for this resource type.
resource "terraform_data" "appinsights_custom_metrics" {
  lifecycle {
    replace_triggered_by = [azurerm_application_insights.this]
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      resource_id="${azurerm_application_insights.this.id}"
      api_version="2020-02-02"

      az rest \
        --method patch \
        --url "https://management.azure.com$${resource_id}?api-version=$${api_version}" \
        --headers "Content-Type=application/json" \
        --body '{"properties":{"CustomMetricsOptedInType":"WithDimensions"}}' \
        -o none

      actual="$(az rest \
        --method get \
        --url "https://management.azure.com$${resource_id}?api-version=$${api_version}" \
        --query "properties.CustomMetricsOptedInType" \
        -o tsv)"

      if [[ "$${actual}" != "WithDimensions" ]]; then
        echo "CustomMetricsOptedInType was not persisted (actual='$${actual}')." >&2
        exit 1
      fi
    EOT
  }

  depends_on = [azurerm_application_insights.this]
}

# =============================================================================
# AI Foundry — Cognitive Services (AIServices) + Project + Deployments
# =============================================================================

# Purge soft-deleted Foundry resource if it exists.
# Uses Cognitive Services deleted-account API and purges only tombstone entries.
resource "null_resource" "purge_foundry" {
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<-EOT
      set -euo pipefail
      deleted_id="$(az cognitiveservices account list-deleted \
        --query "[?name=='${local.foundry_account_name}' && contains(id, '/resourceGroups/${azurerm_resource_group.this.name}/')].id | [0]" \
        -o tsv 2>/dev/null || true)"

      if [[ -n "$${deleted_id}" && "$${deleted_id}" != "null" ]]; then
        az cognitiveservices account purge \
          --name "${local.foundry_account_name}" \
          --resource-group "${azurerm_resource_group.this.name}" \
          --location "${var.location}" \
          -o none

        for _ in {1..30}; do
          still_deleted="$(az cognitiveservices account list-deleted \
            --query "[?name=='${local.foundry_account_name}' && contains(id, '/resourceGroups/${azurerm_resource_group.this.name}/')].id | [0]" \
            -o tsv 2>/dev/null || true)"
          if [[ -z "$${still_deleted}" || "$${still_deleted}" == "null" ]]; then
            break
          fi
          sleep 3
        done
      fi
    EOT
  }
  triggers = {
    always_run = timestamp()
  }
}

resource "azurerm_cognitive_account" "foundry" {
  name                = local.foundry_account_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  kind                = "AIServices"
  sku_name            = var.foundry_sku

  custom_subdomain_name      = local.foundry_account_name
  project_management_enabled = true

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags

  depends_on = [null_resource.purge_foundry]
}

resource "azurerm_cognitive_deployment" "chat" {
  name                 = var.chat_model_name
  cognitive_account_id = azurerm_cognitive_account.foundry.id

  model {
    format  = "OpenAI"
    name    = var.chat_model_name
    version = var.chat_model_version
  }

  sku {
    name     = var.chat_model_sku
    capacity = var.chat_model_capacity
  }

  lifecycle {
    ignore_changes = [sku[0].capacity, model[0].version, rai_policy_name]
  }
}

resource "azurerm_cognitive_deployment" "embeddings" {
  name                 = var.embeddings_model_name
  cognitive_account_id = azurerm_cognitive_account.foundry.id

  model {
    format  = "OpenAI"
    name    = var.embeddings_model_name
    version = var.embeddings_model_version
  }

  sku {
    name     = var.embeddings_model_sku
    capacity = var.embeddings_model_capacity
  }

  depends_on = [azurerm_cognitive_deployment.chat]

  lifecycle {
    ignore_changes = [sku[0].capacity, model[0].version, rai_policy_name]
  }
}

resource "azurerm_cognitive_deployment" "additional_chat" {
  for_each = var.additional_chat_models

  name                 = each.key
  cognitive_account_id = azurerm_cognitive_account.foundry.id

  model {
    format  = "OpenAI"
    name    = each.key
    version = each.value.version
  }

  sku {
    name     = each.value.sku
    capacity = each.value.capacity
  }

  depends_on = [azurerm_cognitive_deployment.embeddings]

  lifecycle {
    ignore_changes = [sku[0].capacity, model[0].version, rai_policy_name]
  }
}

# AI Foundry Project (not yet in azurerm — use azapi)
resource "azapi_resource" "foundry_project" {
  type      = "Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview"
  name      = "proj-${local.name}"
  parent_id = azurerm_cognitive_account.foundry.id
  location  = azurerm_resource_group.this.location

  identity {
    type = "SystemAssigned"
  }

  body = {}

  tags = var.tags

  depends_on = [azurerm_cognitive_account.foundry]
}

# Anthropic Claude model deployments (azapi because azurerm doesn't support modelProviderData yet)
resource "azapi_resource" "claude_deployment" {
  for_each = var.enable_claude ? var.claude_models : {}

  type      = "Microsoft.CognitiveServices/accounts/deployments@2025-10-01-preview"
  name      = each.key
  parent_id = azurerm_cognitive_account.foundry.id

  # azapi schema doesn't include modelProviderData yet — disable validation
  schema_validation_enabled = false

  body = {
    sku = {
      name     = each.value.sku
      capacity = each.value.capacity
    }
    properties = {
      model = {
        format  = "Anthropic"
        name    = each.key
        version = each.value.version
      }
      modelProviderData = {
        organizationName = var.claude_provider_data.organization_name
        countryCode      = var.claude_provider_data.country_code
        industry         = var.claude_provider_data.industry
      }
      versionUpgradeOption = "OnceNewDefaultVersionAvailable"
    }
  }

  depends_on = [azurerm_cognitive_deployment.additional_chat]

  lifecycle {
    ignore_changes = [body.sku.capacity, body.properties.model.version]
  }
}

# =============================================================================
# Google AI — Gemini API (conditional on enable_gemini)
# =============================================================================

# Enable the Generative Language API in the GCP project
resource "google_project_service" "gemini" {
  count = var.enable_gemini ? 1 : 0

  project = var.gcp_project_id
  service = "generativelanguage.googleapis.com"

  disable_on_destroy = false
}

# Enable the API Keys API (required to create API keys via Terraform)
resource "google_project_service" "apikeys" {
  count = var.enable_gemini ? 1 : 0

  project = var.gcp_project_id
  service = "apikeys.googleapis.com"

  disable_on_destroy = false
}

# API key for Gemini (restricted to generative language API)
resource "google_apikeys_key" "gemini" {
  count = var.enable_gemini ? 1 : 0

  name         = "gemini-api-key"
  display_name = "Gemini API Key"
  project      = var.gcp_project_id

  restrictions {
    api_targets {
      service = "generativelanguage.googleapis.com"
    }
  }

  depends_on = [google_project_service.gemini, google_project_service.apikeys]
}

# =============================================================================
# API Management
# =============================================================================

# Purge soft-deleted APIM service if it exists.
# Uses APIM deleted-service API and purges only tombstone entries.
resource "null_resource" "purge_apim" {
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<-EOT
      set -euo pipefail

      deleted_location="$(az apim deletedservice list \
        --query "[?name=='apim-${local.name}' && contains(serviceId, '/resourceGroups/${azurerm_resource_group.this.name}/')].location | [0]" \
        -o tsv 2>/dev/null || true)"

      if [[ -n "$${deleted_location}" && "$${deleted_location}" != "null" ]]; then
        az apim deletedservice purge \
          --service-name "apim-${local.name}" \
          --location "$${deleted_location}" \
          -o none

        for _ in {1..30}; do
          still_deleted="$(az apim deletedservice list \
            --query "[?name=='apim-${local.name}' && contains(serviceId, '/resourceGroups/${azurerm_resource_group.this.name}/')].name | [0]" \
            -o tsv 2>/dev/null || true)"
          if [[ -z "$${still_deleted}" || "$${still_deleted}" == "null" ]]; then
            break
          fi
          sleep 3
        done
      fi
    EOT
  }

  triggers = {
    always_run = timestamp()
  }
}

resource "azurerm_api_management" "this" {
  name                = "apim-${local.name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  publisher_name      = var.apim_publisher_name
  publisher_email     = var.apim_publisher_email
  sku_name            = "${var.apim_sku}_1"

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags

  depends_on = [null_resource.purge_apim]
}

# Wait until APIM control plane reports fully provisioned AND API is responsive.
# Polls provisioningState, then verifies API responsiveness via read-only diagnostic-settings list.
resource "terraform_data" "apim_ready" {
  lifecycle {
    replace_triggered_by = [azurerm_api_management.this]
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      apim_name="${azurerm_api_management.this.name}"
      rg_name="${azurerm_resource_group.this.name}"
      subscription_id="${data.azurerm_client_config.current.subscription_id}"
      resource_id="/subscriptions/$${subscription_id}/resourceGroups/$${rg_name}/providers/Microsoft.ApiManagement/service/$${apim_name}"

      for _ in {1..120}; do
        state="$(az apim show \
          --name "$${apim_name}" \
          --resource-group "$${rg_name}" \
          --query "provisioningState" \
          -o tsv 2>/dev/null || true)"

        if [[ "$${state}" == "Succeeded" ]]; then
          # Verify APIM API is responsive by listing diagnostic settings
          if az monitor diagnostic-settings list \
            --resource "$${resource_id}" \
            >/dev/null 2>&1; then
            exit 0
          fi
        fi

        sleep 10
      done

      echo "Timed out waiting for APIM to be fully ready for diagnostic settings." >&2
      exit 1
    EOT
  }

  depends_on = [azurerm_api_management.this]
}

# APIM Diagnostic Setting — sends platform logs/metrics to Log Analytics
# Managed via AzAPI to avoid create collision on first-run eventual consistency edges.
resource "azapi_update_resource" "apim_diagnostic_setting" {
  type        = "Microsoft.Insights/diagnosticSettings@2021-05-01-preview"
  resource_id = "${azurerm_api_management.this.id}/providers/Microsoft.Insights/diagnosticSettings/apim-to-log-analytics"

  body = {
    properties = {
      workspaceId                 = azurerm_log_analytics_workspace.this.id
      logAnalyticsDestinationType = "Dedicated"
      logs = [
        {
          categoryGroup = "allLogs"
          enabled       = true
          retentionPolicy = {
            enabled = false
            days    = 0
          }
        },
        {
          categoryGroup = "audit"
          enabled       = true
          retentionPolicy = {
            enabled = false
            days    = 0
          }
        }
      ]
      metrics = [
        {
          category = "AllMetrics"
          enabled  = true
          retentionPolicy = {
            enabled = false
            days    = 0
          }
        }
      ]
    }
  }

  depends_on = [terraform_data.apim_ready]
}

# APIM Logger — Application Insights
resource "azurerm_api_management_logger" "appinsights" {
  name                = "appinsights-logger"
  resource_group_name = azurerm_resource_group.this.name
  api_management_name = azurerm_api_management.this.name
  resource_id         = azurerm_application_insights.this.id

  application_insights {
    connection_string = azurerm_application_insights.this.connection_string
  }

  depends_on = [terraform_data.apim_ready]
}

resource "azurerm_api_management_diagnostic" "appinsights" {
  identifier               = "applicationinsights"
  resource_group_name      = azurerm_resource_group.this.name
  api_management_name      = azurerm_api_management.this.name
  api_management_logger_id = azurerm_api_management_logger.appinsights.id

  sampling_percentage = 100.0

  always_log_errors         = true
  log_client_ip             = true
  http_correlation_protocol = "W3C"
  verbosity                 = "information"

  # Log request and response bodies for demo/debugging purposes.
  # ⚠️  See docs/architecture.md Decision 9 for privacy implications.
  frontend_request {
    body_bytes = 8192
  }

  frontend_response {
    body_bytes = 8192
  }

  backend_request {
    body_bytes = 8192
  }

  backend_response {
    body_bytes = 8192
  }

  depends_on = [terraform_data.apim_ready]
}

# API-level diagnostic — enables Application Insights on the OpenAI API
resource "azurerm_api_management_api_diagnostic" "openai_appinsights" {
  identifier               = "applicationinsights"
  resource_group_name      = azurerm_resource_group.this.name
  api_management_name      = azurerm_api_management.this.name
  api_name                 = azurerm_api_management_api.openai.name
  api_management_logger_id = azurerm_api_management_logger.appinsights.id

  sampling_percentage = 100.0

  always_log_errors         = true
  log_client_ip             = true
  http_correlation_protocol = "W3C"
  verbosity                 = "information"

  frontend_request {
    body_bytes = 8192
  }

  frontend_response {
    body_bytes = 8192
  }

  backend_request {
    body_bytes = 8192
  }

  backend_response {
    body_bytes = 8192
  }
}

# Enable custom metrics on the API-level diagnostic (not exposed by azurerm)
resource "azapi_update_resource" "openai_diagnostic_metrics" {
  type        = "Microsoft.ApiManagement/service/apis/diagnostics@2024-05-01"
  resource_id = "${azurerm_api_management.this.id}/apis/${azurerm_api_management_api.openai.name}/diagnostics/applicationinsights"

  body = {
    properties = {
      metrics = true
    }
  }

  depends_on = [azurerm_api_management_api_diagnostic.openai_appinsights]
}

# =============================================================================
# RBAC — APIM Managed Identity → Foundry
# =============================================================================

# Allows APIM to call Foundry (chat + embeddings) via managed identity
resource "azurerm_role_assignment" "apim_foundry_openai_user" {
  scope                = azurerm_cognitive_account.foundry.id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_api_management.this.identity[0].principal_id
}

# Allows APIM to call Foundry Anthropic models via managed identity
resource "azurerm_role_assignment" "apim_foundry_cognitive_user" {
  count = var.enable_claude ? 1 : 0

  scope                = azurerm_cognitive_account.foundry.id
  role_definition_name = "Cognitive Services User"
  principal_id         = azurerm_api_management.this.identity[0].principal_id
}

# =============================================================================
# Entra ID — Consumer App Registrations + Service Principals
# =============================================================================

# API app registration (audience for JWT validation)
resource "azuread_application" "api" {
  display_name = "${local.name}-ai-gateway-api"

  api {
    requested_access_token_version = 2
  }

  app_role {
    allowed_member_types = ["Application"]
    description          = "Access the AI Gateway API"
    display_name         = "AI Gateway Access"
    id                   = "00000000-0000-0000-0000-000000000001"
    enabled              = true
    value                = "AIGateway.Access"
  }

  identifier_uris = ["api://${local.name}-ai-gateway"]
}

resource "azuread_service_principal" "api" {
  client_id = azuread_application.api.client_id
}

# Consumer: Team Alpha
resource "azuread_application" "team_alpha" {
  display_name = "${local.name}-team-alpha"

  required_resource_access {
    resource_app_id = azuread_application.api.client_id

    resource_access {
      id   = "00000000-0000-0000-0000-000000000001"
      type = "Role"
    }
  }
}

resource "azuread_service_principal" "team_alpha" {
  client_id = azuread_application.team_alpha.client_id
}

resource "azuread_application_password" "team_alpha" {
  application_id = azuread_application.team_alpha.id
  display_name   = "demo-secret"

  lifecycle {
    ignore_changes = [end_date]
  }
}

resource "azuread_app_role_assignment" "team_alpha" {
  app_role_id         = "00000000-0000-0000-0000-000000000001"
  principal_object_id = azuread_service_principal.team_alpha.object_id
  resource_object_id  = azuread_service_principal.api.object_id
}

# Consumer: Team Bravo
resource "azuread_application" "team_bravo" {
  display_name = "${local.name}-team-bravo"

  required_resource_access {
    resource_app_id = azuread_application.api.client_id

    resource_access {
      id   = "00000000-0000-0000-0000-000000000001"
      type = "Role"
    }
  }
}

resource "azuread_service_principal" "team_bravo" {
  client_id = azuread_application.team_bravo.client_id
}

resource "azuread_application_password" "team_bravo" {
  application_id = azuread_application.team_bravo.id
  display_name   = "demo-secret"

  lifecycle {
    ignore_changes = [end_date]
  }
}

resource "azuread_app_role_assignment" "team_bravo" {
  app_role_id         = "00000000-0000-0000-0000-000000000001"
  principal_object_id = azuread_service_principal.team_bravo.object_id
  resource_object_id  = azuread_service_principal.api.object_id
}

# Consumer: Team Charlie
resource "azuread_application" "team_charlie" {
  display_name = "${local.name}-team-charlie"

  required_resource_access {
    resource_app_id = azuread_application.api.client_id

    resource_access {
      id   = "00000000-0000-0000-0000-000000000001"
      type = "Role"
    }
  }
}

resource "azuread_service_principal" "team_charlie" {
  client_id = azuread_application.team_charlie.client_id
}

resource "azuread_application_password" "team_charlie" {
  application_id = azuread_application.team_charlie.id
  display_name   = "demo-secret"

  lifecycle {
    ignore_changes = [end_date]
  }
}

resource "azuread_app_role_assignment" "team_charlie" {
  app_role_id         = "00000000-0000-0000-0000-000000000001"
  principal_object_id = azuread_service_principal.team_charlie.object_id
  resource_object_id  = azuread_service_principal.api.object_id
}

# =============================================================================
# APIM — Backends
# =============================================================================

# Chat backend — Foundry OpenAI-compatible endpoint (managed identity auth)
resource "azurerm_api_management_backend" "chat" {
  name                = "foundry-chat"
  resource_group_name = azurerm_resource_group.this.name
  api_management_name = azurerm_api_management.this.name
  protocol            = "http"
  url                 = "${azurerm_cognitive_account.foundry.endpoint}openai"

  tls {
    validate_certificate_chain = true
    validate_certificate_name  = true
  }

  # Circuit breaker rules are managed by azapi_update_resource below;
  # ignore drift so azurerm doesn't strip them on every apply.
  lifecycle {
    ignore_changes = [circuit_breaker_rule]
  }

  depends_on = [terraform_data.apim_ready]
}

# Circuit breaker on the Foundry chat backend (not yet in azurerm — use azapi)
resource "azapi_update_resource" "chat_circuit_breaker" {
  type        = "Microsoft.ApiManagement/service/backends@2024-06-01-preview"
  resource_id = "${azurerm_api_management.this.id}/backends/${azurerm_api_management_backend.chat.name}"

  body = {
    properties = {
      circuitBreaker = {
        rules = [
          {
            name = "foundryBreakerRule"
            failureCondition = {
              count    = var.circuit_breaker_failure_count
              interval = var.circuit_breaker_interval
              statusCodeRanges = [
                { min = 429, max = 429 },
                { min = 500, max = 599 }
              ]
            }
            tripDuration     = var.circuit_breaker_trip_duration
            acceptRetryAfter = var.circuit_breaker_accept_retry_after
          }
        ]
      }
    }
  }

  depends_on = [azurerm_api_management_backend.chat]
}

# Embeddings backend — for semantic cache (managed identity auth)
resource "azurerm_api_management_backend" "embeddings" {
  name                = "foundry-embeddings"
  resource_group_name = azurerm_resource_group.this.name
  api_management_name = azurerm_api_management.this.name
  protocol            = "http"
  url                 = "https://fndry-${local.name}.cognitiveservices.azure.com/openai/deployments/${var.embeddings_model_name}/embeddings"

  tls {
    validate_certificate_chain = true
    validate_certificate_name  = true
  }

  depends_on = [terraform_data.apim_ready]
}

# Gemini backend — Google AI OpenAI-compatible endpoint (API key auth via Key Vault)
resource "azurerm_api_management_backend" "gemini" {
  count = var.enable_gemini ? 1 : 0

  name                = "gemini-chat"
  resource_group_name = azurerm_resource_group.this.name
  api_management_name = azurerm_api_management.this.name
  protocol            = "http"
  url                 = "https://generativelanguage.googleapis.com/v1beta/openai"

  credentials {
    header = {
      "Authorization" = "Bearer {{gemini-api-key}}"
    }
  }

  tls {
    validate_certificate_chain = true
    validate_certificate_name  = true
  }

  depends_on = [
    terraform_data.apim_ready,
    azurerm_api_management_named_value.gemini_api_key,
  ]
}

# Anthropic backend — Foundry Claude endpoint (managed identity auth)
resource "azurerm_api_management_backend" "anthropic" {
  count = var.enable_claude ? 1 : 0

  name                = "foundry-anthropic"
  resource_group_name = azurerm_resource_group.this.name
  api_management_name = azurerm_api_management.this.name
  protocol            = "http"
  url                 = replace(azurerm_cognitive_account.foundry.endpoint, ".cognitiveservices.azure.com/", ".services.ai.azure.com/anthropic")

  tls {
    validate_certificate_chain = true
    validate_certificate_name  = true
  }

  depends_on = [terraform_data.apim_ready]
}

# =============================================================================
# APIM — Products
# =============================================================================

# TODO Delete starter & unlimited products. Otherwise subsequent deployments/destroys will fail (they have subscriptions)

resource "azurerm_api_management_product" "standard" {
  product_id            = "ai-standard"
  resource_group_name   = azurerm_resource_group.this.name
  api_management_name   = azurerm_api_management.this.name
  display_name          = "AI Standard"
  description           = "Standard tier — ${var.standard_tokens_per_minute} tokens/min, ${var.standard_token_quota} hourly quota."
  subscription_required = true
  approval_required     = false
  published             = true

  depends_on = [terraform_data.apim_ready]
}

resource "azurerm_api_management_product" "premium" {
  product_id            = "ai-premium"
  resource_group_name   = azurerm_resource_group.this.name
  api_management_name   = azurerm_api_management.this.name
  display_name          = "AI Premium"
  description           = "Premium tier — ${var.premium_tokens_per_minute} tokens/min, ${var.premium_token_quota} hourly quota."
  subscription_required = true
  approval_required     = false
  published             = true

  depends_on = [terraform_data.apim_ready]
}

# =============================================================================
# APIM — Subscriptions
# =============================================================================

resource "azurerm_api_management_subscription" "alpha_standard" {
  resource_group_name = azurerm_resource_group.this.name
  api_management_name = azurerm_api_management.this.name
  product_id          = azurerm_api_management_product.standard.id
  display_name        = "Team Alpha — Standard"
  state               = "active"
}

resource "azurerm_api_management_subscription" "bravo_premium" {
  resource_group_name = azurerm_resource_group.this.name
  api_management_name = azurerm_api_management.this.name
  product_id          = azurerm_api_management_product.premium.id
  display_name        = "Team Bravo — Premium"
  state               = "active"
}

resource "azurerm_api_management_subscription" "charlie_standard" {
  resource_group_name = azurerm_resource_group.this.name
  api_management_name = azurerm_api_management.this.name
  product_id          = azurerm_api_management_product.standard.id
  display_name        = "Team Charlie — Standard"
  state               = "active"
}

# =============================================================================
# APIM — API Definition
# =============================================================================

resource "azurerm_api_management_api" "openai" {
  name                  = "openai-gateway"
  resource_group_name   = azurerm_resource_group.this.name
  api_management_name   = azurerm_api_management.this.name
  display_name          = "OpenAI Gateway"
  description           = "AI Gateway fronting Azure AI Foundry with billing, caching, and token metering."
  path                  = "openai"
  protocols             = ["https"]
  revision              = "1"
  subscription_required = true

  subscription_key_parameter_names {
    header = "api-key"
    query  = "api-key"
  }

  depends_on = [terraform_data.apim_ready]
}

# Wildcard operations to proxy all OpenAI-compatible paths
resource "azurerm_api_management_api_operation" "post_wildcard" {
  operation_id        = "post-wildcard"
  api_name            = azurerm_api_management_api.openai.name
  resource_group_name = azurerm_resource_group.this.name
  api_management_name = azurerm_api_management.this.name
  display_name        = "POST Wildcard"
  method              = "POST"
  url_template        = "/*"
}

resource "azurerm_api_management_api_operation" "get_wildcard" {
  operation_id        = "get-wildcard"
  api_name            = azurerm_api_management_api.openai.name
  resource_group_name = azurerm_resource_group.this.name
  api_management_name = azurerm_api_management.this.name
  display_name        = "GET Wildcard"
  method              = "GET"
  url_template        = "/*"
}

# Associate API with both products
resource "azurerm_api_management_product_api" "standard" {
  api_name            = azurerm_api_management_api.openai.name
  product_id          = azurerm_api_management_product.standard.product_id
  resource_group_name = azurerm_resource_group.this.name
  api_management_name = azurerm_api_management.this.name
}

resource "azurerm_api_management_product_api" "premium" {
  api_name            = azurerm_api_management_api.openai.name
  product_id          = azurerm_api_management_product.premium.product_id
  resource_group_name = azurerm_resource_group.this.name
  api_management_name = azurerm_api_management.this.name
}

# =============================================================================
# APIM — Anthropic API Definition (Claude Code compatible)
# =============================================================================

resource "azurerm_api_management_api" "anthropic" {
  count = var.enable_claude ? 1 : 0

  name                  = "anthropic-gateway"
  resource_group_name   = azurerm_resource_group.this.name
  api_management_name   = azurerm_api_management.this.name
  display_name          = "Anthropic Gateway"
  description           = "AI Gateway for Anthropic Claude models via Azure AI Foundry. Claude Code compatible."
  path                  = "anthropic"
  protocols             = ["https"]
  revision              = "1"
  subscription_required = true

  subscription_key_parameter_names {
    header = "api-key"
    query  = "api-key"
  }

  depends_on = [terraform_data.apim_ready]
}

resource "azurerm_api_management_api_operation" "anthropic_post" {
  count = var.enable_claude ? 1 : 0

  operation_id        = "post-wildcard"
  api_name            = azurerm_api_management_api.anthropic[0].name
  resource_group_name = azurerm_resource_group.this.name
  api_management_name = azurerm_api_management.this.name
  display_name        = "POST Wildcard"
  method              = "POST"
  url_template        = "/*"
}

resource "azurerm_api_management_api_operation" "anthropic_get" {
  count = var.enable_claude ? 1 : 0

  operation_id        = "get-wildcard"
  api_name            = azurerm_api_management_api.anthropic[0].name
  resource_group_name = azurerm_resource_group.this.name
  api_management_name = azurerm_api_management.this.name
  display_name        = "GET Wildcard"
  method              = "GET"
  url_template        = "/*"
}

resource "azurerm_api_management_product_api" "standard_anthropic" {
  count = var.enable_claude ? 1 : 0

  api_name            = azurerm_api_management_api.anthropic[0].name
  product_id          = azurerm_api_management_product.standard.product_id
  resource_group_name = azurerm_resource_group.this.name
  api_management_name = azurerm_api_management.this.name
}

resource "azurerm_api_management_product_api" "premium_anthropic" {
  count = var.enable_claude ? 1 : 0

  api_name            = azurerm_api_management_api.anthropic[0].name
  product_id          = azurerm_api_management_product.premium.product_id
  resource_group_name = azurerm_resource_group.this.name
  api_management_name = azurerm_api_management.this.name
}

# =============================================================================
# APIM — Policies
# =============================================================================

# API-level policy (backend routing, caching, metrics)
resource "azurerm_api_management_api_policy" "openai" {
  api_name            = azurerm_api_management_api.openai.name
  resource_group_name = azurerm_resource_group.this.name
  api_management_name = azurerm_api_management.this.name

  xml_content = templatefile("${path.module}/policies/api-openai.xml", {
    chat_backend_id       = azurerm_api_management_backend.chat.name
    embeddings_backend_id = azurerm_api_management_backend.embeddings.name
    gemini_backend_id     = var.enable_gemini ? azurerm_api_management_backend.gemini[0].name : ""
    gemini_models_csv     = var.enable_gemini ? join(", ", [for m in var.gemini_models : "\"${m}\""]) : ""
    enable_gemini         = var.enable_gemini
    metric_namespace      = var.metric_namespace
    cache_score_threshold = var.cache_score_threshold
    cache_duration        = var.cache_duration_seconds
    tenant_id             = data.azurerm_client_config.current.tenant_id
    api_audience          = one(azuread_application.api.identifier_uris)
    api_client_id         = azuread_application.api.client_id
    fallback_map_json     = replace(jsonencode(var.model_fallback_map), "\"", "&quot;")
    foundry_endpoint      = azurerm_cognitive_account.foundry.endpoint
  })

  depends_on = [
    azurerm_api_management_backend.chat,
    azurerm_api_management_backend.embeddings,
  ]
}

# API-level policy: Anthropic (Claude Code compatible routing + metrics)
resource "azurerm_api_management_api_policy" "anthropic" {
  count = var.enable_claude ? 1 : 0

  api_name            = azurerm_api_management_api.anthropic[0].name
  resource_group_name = azurerm_resource_group.this.name
  api_management_name = azurerm_api_management.this.name

  xml_content = templatefile("${path.module}/policies/api-anthropic.xml", {
    anthropic_backend_id = azurerm_api_management_backend.anthropic[0].name
    metric_namespace     = var.metric_namespace
    tenant_id            = data.azurerm_client_config.current.tenant_id
    api_audience         = one(azuread_application.api.identifier_uris)
    api_client_id        = azuread_application.api.client_id
  })

  depends_on = [azurerm_api_management_backend.anthropic]
}

# API-level diagnostic: Anthropic — enables Application Insights
resource "azurerm_api_management_api_diagnostic" "anthropic_appinsights" {
  count = var.enable_claude ? 1 : 0

  identifier               = "applicationinsights"
  resource_group_name      = azurerm_resource_group.this.name
  api_management_name      = azurerm_api_management.this.name
  api_name                 = azurerm_api_management_api.anthropic[0].name
  api_management_logger_id = azurerm_api_management_logger.appinsights.id

  sampling_percentage = 100.0

  always_log_errors         = true
  log_client_ip             = true
  http_correlation_protocol = "W3C"
  verbosity                 = "information"

  frontend_request {
    body_bytes = 8192
  }

  frontend_response {
    body_bytes = 8192
  }

  backend_request {
    body_bytes = 8192
  }

  backend_response {
    body_bytes = 8192
  }
}

# Enable custom metrics on Anthropic API diagnostic
resource "azapi_update_resource" "anthropic_diagnostic_metrics" {
  count = var.enable_claude ? 1 : 0

  type        = "Microsoft.ApiManagement/service/apis/diagnostics@2024-05-01"
  resource_id = "${azurerm_api_management.this.id}/apis/${azurerm_api_management_api.anthropic[0].name}/diagnostics/applicationinsights"

  body = {
    properties = {
      metrics = true
    }
  }

  depends_on = [azurerm_api_management_api_diagnostic.anthropic_appinsights]
}

# Product-level policy: Standard
resource "azurerm_api_management_product_policy" "standard" {
  product_id          = azurerm_api_management_product.standard.product_id
  resource_group_name = azurerm_resource_group.this.name
  api_management_name = azurerm_api_management.this.name

  xml_content = templatefile("${path.module}/policies/product-standard.xml", {
    tokens_per_minute = var.standard_tokens_per_minute
    token_quota       = var.standard_token_quota
  })
}

# Product-level policy: Premium
resource "azurerm_api_management_product_policy" "premium" {
  product_id          = azurerm_api_management_product.premium.product_id
  resource_group_name = azurerm_resource_group.this.name
  api_management_name = azurerm_api_management.this.name

  xml_content = templatefile("${path.module}/policies/product-premium.xml", {
    tokens_per_minute = var.premium_tokens_per_minute
    token_quota       = var.premium_token_quota
  })
}

# =============================================================================
# Key Vault — stores Gemini API key + optional consumer credentials for tests
# =============================================================================

resource "azurerm_key_vault" "this" {
  name                       = "kv-${local.name}"
  resource_group_name        = azurerm_resource_group.this.name
  location                   = azurerm_resource_group.this.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = false
  soft_delete_retention_days = 7

  tags = var.tags
}

# Deployer gets Secrets Officer so Terraform can write secrets
resource "azurerm_role_assignment" "kv_deployer_secrets_officer" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# APIM managed identity gets Secrets User to read Key Vault-backed named values
resource "azurerm_role_assignment" "kv_apim_secrets_user" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_api_management.this.identity[0].principal_id
}

# Additional readers (e.g., a developer running tests from a different identity)
resource "azurerm_role_assignment" "kv_reader" {
  for_each = var.enable_key_vault ? toset(var.key_vault_reader_object_ids) : toset([])

  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = each.value
}

# Gemini API key stored in Key Vault
resource "azurerm_key_vault_secret" "gemini_api_key" {
  count = var.enable_gemini ? 1 : 0

  name         = "gemini-api-key"
  value        = google_apikeys_key.gemini[0].key_string
  key_vault_id = azurerm_key_vault.this.id

  depends_on = [azurerm_role_assignment.kv_deployer_secrets_officer]
}

# APIM named value backed by Key Vault secret
resource "azurerm_api_management_named_value" "gemini_api_key" {
  count = var.enable_gemini ? 1 : 0

  name                = "gemini-api-key"
  resource_group_name = azurerm_resource_group.this.name
  api_management_name = azurerm_api_management.this.name
  display_name        = "gemini-api-key"
  secret              = true

  value_from_key_vault {
    secret_id = azurerm_key_vault_secret.gemini_api_key[0].versionless_id
  }

  depends_on = [
    terraform_data.apim_ready,
    azurerm_role_assignment.kv_apim_secrets_user,
  ]
}

# Optional consumer test secrets
locals {
  kv_secrets = var.enable_key_vault ? {
    "team-alpha-client-id"       = azuread_application.team_alpha.client_id
    "team-alpha-client-secret"   = azuread_application_password.team_alpha.value
    "team-bravo-client-id"       = azuread_application.team_bravo.client_id
    "team-bravo-client-secret"   = azuread_application_password.team_bravo.value
    "team-charlie-client-id"     = azuread_application.team_charlie.client_id
    "team-charlie-client-secret" = azuread_application_password.team_charlie.value
    "alpha-subscription-key"     = azurerm_api_management_subscription.alpha_standard.primary_key
    "bravo-subscription-key"     = azurerm_api_management_subscription.bravo_premium.primary_key
    "charlie-subscription-key"   = azurerm_api_management_subscription.charlie_standard.primary_key
  } : {}
}

resource "azurerm_key_vault_secret" "this" {
  for_each = local.kv_secrets

  name         = each.key
  value        = each.value
  key_vault_id = azurerm_key_vault.this.id

  depends_on = [azurerm_role_assignment.kv_deployer_secrets_officer]
}

# =============================================================================
# Azure Monitor Workbook — Billing Dashboard
# =============================================================================

resource "azurerm_application_insights_workbook" "billing" {
  name                = "d2e3f4a5-b6c7-8d9e-0f1a-2b3c4d5e6f7a"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  display_name        = "AI Gateway Billing Dashboard"
  source_id           = lower(azurerm_application_insights.this.id)
  tags                = var.tags

  data_json = replace(
    replace(
      file("${path.module}/../workbook/ai-gateway-billing.json"),
      "SUBSCRIPTION_LOOKUP",
      join("", [
        "datatable(SubscriptionId: string, TeamName: string)[",
        "\\\"${azurerm_api_management_subscription.alpha_standard.subscription_id}\\\", \\\"Team Alpha (Standard)\\\", ",
        "\\\"${azurerm_api_management_subscription.bravo_premium.subscription_id}\\\", \\\"Team Bravo (Premium)\\\", ",
        "\\\"${azurerm_api_management_subscription.charlie_standard.subscription_id}\\\", \\\"Team Charlie (Standard)\\\"",
        "]",
      ])
    ),
    "MODEL_PRICING",
    join("", [
      "datatable(Model: string, PromptPer1K: real, CompletionPer1K: real)[",
      join(", ", [
        for name, pricing in var.model_pricing :
        "\\\"${name}\\\", ${pricing.prompt_per_1k}, ${pricing.completion_per_1k}"
      ]),
      "]",
    ])
  )
}
