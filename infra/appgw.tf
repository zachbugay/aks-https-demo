resource "azurerm_public_ip" "agw" {
  name                = "pip-agw-${local.name}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.common_tags

  lifecycle {
    ignore_changes = [
      ip_tags,
      zones,
    ]
  }
}

resource "azurerm_user_assigned_identity" "agw" {
  name                = "uami-agw-${local.name}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  tags                = local.common_tags
}

resource "azurerm_role_assignment" "agw_kv_secrets_user" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.agw.principal_id
}

resource "azurerm_role_assignment" "agw_kv_certificate_user" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Certificate User"
  principal_id         = azurerm_user_assigned_identity.agw.principal_id
}

resource "azurerm_key_vault_certificate" "frontend_cert" {
  name         = "${var.workload_name}-${local.token}-frontend-tls"
  key_vault_id = azurerm_key_vault.kv.id

  certificate_policy {
    issuer_parameters {
      name = "Self"
    }

    key_properties {
      exportable = true
      key_size   = 2048
      key_type   = "RSA"
      reuse_key  = true
    }

    secret_properties {
      content_type = "application/x-pkcs12"
    }

    x509_certificate_properties {
      subject            = "CN=${var.workload_name}-${local.token}"
      validity_in_months = 12
      key_usage = [
        "digitalSignature",
        "keyEncipherment",
      ]

      subject_alternative_names {
        dns_names = [var.httpbin_hostname, var.podinfo_hostname]
      }
    }
  }

  depends_on = [azurerm_role_assignment.kv_admin]
}

resource "azurerm_application_gateway" "agw" {
  name                = "agw-${local.name}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  tags                = local.common_tags

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 2
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.agw.id]
  }

  gateway_ip_configuration {
    name      = "agw-ip-config"
    subnet_id = azurerm_subnet.snet-agw.id
  }

  frontend_port {
    name = "https-port"
    port = 443
  }

  frontend_port {
    name = "http-port"
    port = 80
  }

  frontend_ip_configuration {
    name                 = local.frontend_ip_configuration_name
    public_ip_address_id = azurerm_public_ip.agw.id
  }

  ssl_certificate {
    name                = "app-frontend"
    key_vault_secret_id = azurerm_key_vault_certificate.frontend_cert.versionless_secret_id
  }

  trusted_root_certificate {
    name = "demo-ca-root-cert"
    data = base64encode(tls_self_signed_cert.demo_ca.cert_pem)
  }

  backend_address_pool {
    name         = "istio-gateway-pool"
    ip_addresses = [var.k8s_gateway_internal_ip]
  }

  probe {
    name                = "istio-httpbin-probe"
    protocol            = "Https"
    host                = var.httpbin_hostname
    path                = "/get"
    interval            = 30
    timeout             = 30
    unhealthy_threshold = 3

    match {
      status_code = ["200-399"]
    }
  }

  probe {
    name                = "istio-podinfo-probe"
    protocol            = "Https"
    host                = var.podinfo_hostname
    path                = "/healthz"
    interval            = 30
    timeout             = 30
    unhealthy_threshold = 3

    match {
      status_code = ["200-399"]
    }
  }

  backend_http_settings {
    name                                = "httpbin-http-setting"
    cookie_based_affinity               = "Disabled"
    port                                = 443
    protocol                            = "Https"
    request_timeout                     = 30
    pick_host_name_from_backend_address = false
    host_name                           = var.httpbin_hostname
    probe_name                          = "istio-httpbin-probe"
    trusted_root_certificate_names      = ["demo-ca-root-cert"]
  }

  backend_http_settings {
    name                                = "podinfo-http-setting"
    cookie_based_affinity               = "Disabled"
    port                                = 443
    protocol                            = "Https"
    request_timeout                     = 30
    pick_host_name_from_backend_address = false
    host_name                           = var.podinfo_hostname
    probe_name                          = "istio-podinfo-probe"
    trusted_root_certificate_names      = ["demo-ca-root-cert"]
  }

  http_listener {
    name                           = "httpbin-https-listener"
    frontend_ip_configuration_name = local.frontend_ip_configuration_name
    frontend_port_name             = "https-port"
    protocol                       = "Https"
    host_name                      = var.httpbin_hostname
    ssl_certificate_name           = "app-frontend"
  }

  http_listener {
    name                           = "podinfo-https-listener"
    frontend_ip_configuration_name = local.frontend_ip_configuration_name
    frontend_port_name             = "https-port"
    protocol                       = "Https"
    host_name                      = var.podinfo_hostname
    ssl_certificate_name           = "app-frontend"
  }

  http_listener {
    name                           = "httpbin-http-listener"
    frontend_ip_configuration_name = local.frontend_ip_configuration_name
    frontend_port_name             = "http-port"
    protocol                       = "Http"
    host_name                      = var.httpbin_hostname
  }

  http_listener {
    name                           = "podinfo-http-listener"
    frontend_ip_configuration_name = local.frontend_ip_configuration_name
    frontend_port_name             = "http-port"
    protocol                       = "Http"
    host_name                      = var.podinfo_hostname
  }

  request_routing_rule {
    name                       = "httpbin-https-rule"
    priority                   = 100
    rule_type                  = "Basic"
    http_listener_name         = "httpbin-https-listener"
    backend_address_pool_name  = "istio-gateway-pool"
    backend_http_settings_name = "httpbin-http-setting"
  }

  request_routing_rule {
    name                       = "podinfo-https-rule"
    priority                   = 110
    rule_type                  = "Basic"
    http_listener_name         = "podinfo-https-listener"
    backend_address_pool_name  = "istio-gateway-pool"
    backend_http_settings_name = "podinfo-http-setting"
  }

  redirect_configuration {
    name                 = "httpbin-http-redirect"
    redirect_type        = "Permanent"
    target_listener_name = "httpbin-https-listener"
    include_path         = true
    include_query_string = true
  }

  redirect_configuration {
    name                 = "podinfo-http-redirect"
    redirect_type        = "Permanent"
    target_listener_name = "podinfo-https-listener"
    include_path         = true
    include_query_string = true
  }

  request_routing_rule {
    name                        = "httpbin-http-redirect-rule"
    priority                    = 90
    rule_type                   = "Basic"
    http_listener_name          = "httpbin-http-listener"
    redirect_configuration_name = "httpbin-http-redirect"
  }

  request_routing_rule {
    name                        = "podinfo-http-redirect-rule"
    priority                    = 80
    rule_type                   = "Basic"
    http_listener_name          = "podinfo-http-listener"
    redirect_configuration_name = "podinfo-http-redirect"
  }

  depends_on = [
    azurerm_role_assignment.agw_kv_secrets_user,
    azurerm_role_assignment.agw_kv_certificate_user,
  ]
}
