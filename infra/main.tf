provider "azurerm" {
  resource_provider_registrations = "none"
  storage_use_azuread             = true
  use_oidc                        = true
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
    key_vault {
      purge_soft_delete_on_destroy = true
    }
    log_analytics_workspace {
      permanently_delete_on_destroy = true
    }
  }
}

data "azurerm_subscription" "current" {}
data "azurerm_client_config" "current" {}
data "http" "current_ip" {
  url = "https://ipv4.icanhazip.com"
}

resource "random_string" "deployment" {
  length  = 4
  special = false
  upper   = false
}

locals {
  location         = module.avm-utl-regions.regions_by_name[var.location]
  token            = random_string.deployment.result
  enable_telemetry = false
  name             = "${var.environment}-${var.workload_name}-${local.location.geo_code}-${local.token}"

  # Application Gateway specifics.
  backend_address_pool_name      = "${azurerm_virtual_network.vnet.name}-beap"
  frontend_port_name             = "${azurerm_virtual_network.vnet.name}-feport"
  frontend_ip_configuration_name = "${azurerm_virtual_network.vnet.name}-feip"
  http_setting_name              = "${azurerm_virtual_network.vnet.name}-be-htst"
  listener_name                  = "${azurerm_virtual_network.vnet.name}-httplstn"
  request_routing_rule_name      = "${azurerm_virtual_network.vnet.name}-rqrt"
  redirect_configuration_name    = "${azurerm_virtual_network.vnet.name}-rdrcfg"

  common_tags = {
    environment = var.environment
    region      = local.location.display_name
    costcenter  = "1234abcd"
    opsteam     = "cloud-operations"
  }
}

module "avm-utl-regions" {
  source           = "Azure/avm-utl-regions/azurerm"
  version          = "0.12.0"
  enable_telemetry = local.enable_telemetry
}

resource "azurerm_resource_group" "rg" {
  name     = "rg-${local.name}"
  location = local.location.name
  tags     = local.common_tags
}

### For the KV
resource "azurerm_key_vault" "kv" {
  name                          = "kv-${local.name}"
  location                      = azurerm_resource_group.rg.location
  resource_group_name           = azurerm_resource_group.rg.name
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  purge_protection_enabled      = false
  rbac_authorization_enabled    = true
  public_network_access_enabled = true
  sku_name                      = "standard"

  tags = merge(local.common_tags, {
    SecurityControl = "Ignore"
  })
}

resource "azurerm_role_assignment" "kv_admin" {
  principal_id         = data.azurerm_client_config.current.object_id
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Administrator"
}

resource "tls_private_key" "demo_ca" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_self_signed_cert" "demo_ca" {
  private_key_pem       = tls_private_key.demo_ca.private_key_pem
  is_ca_certificate     = true
  validity_period_hours = 2160 # 90d
  early_renewal_hours   = 720  # 30d

  subject {
    common_name  = "demo-ca"
    organization = "aks-https-demo"
  }

  allowed_uses = [
    "cert_signing",
    "crl_signing",
    "digital_signature",
  ]
}

resource "kubernetes_namespace_v1" "cert_manager" {
  metadata {
    name = "cert-manager"
  }

  lifecycle {
    ignore_changes = [
      metadata[0].labels,
      metadata[0].annotations,
    ]
  }
}

resource "kubernetes_secret_v1" "demo_ca" {
  metadata {
    name      = "demo-ca"
    namespace = kubernetes_namespace_v1.cert_manager.metadata[0].name
  }

  type = "kubernetes.io/tls"

  data = {
    "tls.crt" = tls_self_signed_cert.demo_ca.cert_pem
    "tls.key" = tls_private_key.demo_ca.private_key_pem
    "ca.crt"  = tls_self_signed_cert.demo_ca.cert_pem
  }
}
