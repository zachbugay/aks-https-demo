locals {
  agw_ssl_certificate_name          = "app-frontend"
  agw_trusted_root_certificate_name = "demo-ca-root-cert"
  agw_backend_address_pool_name     = "istio-gateway-pool"
  agw_https_port_name               = "https-port"
  agw_http_port_name                = "http-port"

  # Every application shares the same frontend port pair, enforced by variable validation.
  agw_frontend_ports = {
    (local.agw_https_port_name) = one(distinct([for app in var.appgw_applications : app.https_port]))
    (local.agw_http_port_name)  = one(distinct([for app in var.appgw_applications : app.http_port]))
  }

  # Resolved application definitions with the derived Application Gateway child resource names.
  agw_applications = {
    for key, app in var.appgw_applications : key => merge(app, {
      hostname                    = app.hostname
      probe_name                  = "istio-${key}-probe"
      backend_http_settings_name  = "${key}-http-setting"
      https_listener_name         = "${key}-https-listener"
      http_listener_name          = "${key}-http-listener"
      https_rule_name             = "${key}-https-rule"
      redirect_configuration_name = "${key}-http-redirect"
      http_redirect_rule_name     = "${key}-http-redirect-rule"
      url_path_map_name           = app.rule_type == "PathBasedRouting" ? "${key}-path-map" : null
    })
  }

  # URL path maps are only generated for applications using path based routing.
  agw_url_path_maps = {
    for key, app in local.agw_applications : app.url_path_map_name => {
      default_backend_address_pool_name  = local.agw_backend_address_pool_name
      default_backend_http_settings_name = app.backend_http_settings_name
      path_rules = [
        for rule in app.path_rules : {
          name                       = rule.name
          paths                      = rule.paths
          backend_address_pool_name  = local.agw_backend_address_pool_name
          backend_http_settings_name = local.agw_applications[coalesce(rule.backend_app, key)].backend_http_settings_name
        }
      ]
    } if app.rule_type == "PathBasedRouting"
  }

  agw_hostnames = [for key in sort(keys(local.agw_applications)) : local.agw_applications[key].hostname]

  agw_http_listeners = merge(
    {
      for key, app in local.agw_applications : app.https_listener_name => {
        host_name            = app.hostname
        frontend_port_name   = local.agw_https_port_name
        protocol             = "Https"
        ssl_certificate_name = local.agw_ssl_certificate_name
      }
    },
    {
      for key, app in local.agw_applications : app.http_listener_name => {
        host_name            = app.hostname
        frontend_port_name   = local.agw_http_port_name
        protocol             = "Http"
        ssl_certificate_name = null
      }
    }
  )

  agw_request_routing_rules = merge(
    {
      for key, app in local.agw_applications : app.https_rule_name => {
        rule_type                   = app.rule_type
        priority                    = app.https_rule_priority
        http_listener_name          = app.https_listener_name
        backend_address_pool_name   = app.rule_type == "PathBasedRouting" ? null : local.agw_backend_address_pool_name
        backend_http_settings_name  = app.rule_type == "PathBasedRouting" ? null : app.backend_http_settings_name
        redirect_configuration_name = null
        url_path_map_name           = app.url_path_map_name
      }
    },
    {
      # The HTTP listener redirects every path to HTTPS, so this rule is always Basic.
      for key, app in local.agw_applications : app.http_redirect_rule_name => {
        rule_type                   = "Basic"
        priority                    = app.http_redirect_rule_priority
        http_listener_name          = app.http_listener_name
        backend_address_pool_name   = null
        backend_http_settings_name  = null
        redirect_configuration_name = app.redirect_configuration_name
        url_path_map_name           = null
      }
    }
  )
}

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
        dns_names = local.agw_hostnames
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

  frontend_ip_configuration {
    name                 = local.frontend_ip_configuration_name
    public_ip_address_id = azurerm_public_ip.agw.id
  }

  ssl_certificate {
    name                = local.agw_ssl_certificate_name
    key_vault_secret_id = azurerm_key_vault_certificate.frontend_cert.versionless_secret_id
  }

  trusted_root_certificate {
    name = local.agw_trusted_root_certificate_name
    data = base64encode(tls_self_signed_cert.demo_ca.cert_pem)
  }

  backend_address_pool {
    name         = local.agw_backend_address_pool_name
    ip_addresses = [var.k8s_gateway_internal_ip]
  }

  dynamic "frontend_port" {
    for_each = local.agw_frontend_ports

    content {
      name = frontend_port.key
      port = frontend_port.value
    }
  }

  dynamic "probe" {
    for_each = local.agw_applications

    content {
      name                = probe.value.probe_name
      protocol            = probe.value.probe_protocol
      host                = probe.value.hostname
      path                = probe.value.probe_path
      interval            = probe.value.probe_interval
      timeout             = probe.value.probe_timeout
      unhealthy_threshold = probe.value.probe_unhealthy_threshold

      match {
        status_code = probe.value.probe_status_codes
      }
    }
  }

  dynamic "backend_http_settings" {
    for_each = local.agw_applications

    content {
      name                                = backend_http_settings.value.backend_http_settings_name
      cookie_based_affinity               = backend_http_settings.value.cookie_based_affinity
      port                                = backend_http_settings.value.backend_port
      protocol                            = backend_http_settings.value.backend_protocol
      request_timeout                     = backend_http_settings.value.backend_request_timeout
      pick_host_name_from_backend_address = false
      host_name                           = backend_http_settings.value.hostname
      probe_name                          = backend_http_settings.value.probe_name
      trusted_root_certificate_names      = [local.agw_trusted_root_certificate_name]
    }
  }

  dynamic "http_listener" {
    for_each = local.agw_http_listeners

    content {
      name                           = http_listener.key
      frontend_ip_configuration_name = local.frontend_ip_configuration_name
      frontend_port_name             = http_listener.value.frontend_port_name
      protocol                       = http_listener.value.protocol
      host_name                      = http_listener.value.host_name
      ssl_certificate_name           = http_listener.value.ssl_certificate_name
    }
  }

  dynamic "redirect_configuration" {
    for_each = local.agw_applications

    content {
      name                 = redirect_configuration.value.redirect_configuration_name
      redirect_type        = redirect_configuration.value.redirect_type
      target_listener_name = redirect_configuration.value.https_listener_name
      include_path         = true
      include_query_string = true
    }
  }

  dynamic "request_routing_rule" {
    for_each = local.agw_request_routing_rules

    content {
      name                        = request_routing_rule.key
      priority                    = request_routing_rule.value.priority
      rule_type                   = request_routing_rule.value.rule_type
      http_listener_name          = request_routing_rule.value.http_listener_name
      backend_address_pool_name   = request_routing_rule.value.backend_address_pool_name
      backend_http_settings_name  = request_routing_rule.value.backend_http_settings_name
      redirect_configuration_name = request_routing_rule.value.redirect_configuration_name
      url_path_map_name           = request_routing_rule.value.url_path_map_name
    }
  }

  dynamic "url_path_map" {
    for_each = local.agw_url_path_maps

    content {
      name                               = url_path_map.key
      default_backend_address_pool_name  = url_path_map.value.default_backend_address_pool_name
      default_backend_http_settings_name = url_path_map.value.default_backend_http_settings_name

      dynamic "path_rule" {
        for_each = url_path_map.value.path_rules

        content {
          name                       = path_rule.value.name
          paths                      = path_rule.value.paths
          backend_address_pool_name  = path_rule.value.backend_address_pool_name
          backend_http_settings_name = path_rule.value.backend_http_settings_name
        }
      }
    }
  }

  lifecycle {
    precondition {
      condition     = alltrue([for key, app in local.agw_applications : app.hostname != ""])
      error_message = "Every entry in appgw_applications must set `hostname`, or match a variable that provides one (httpbin, podinfo)."
    }
  }

  depends_on = [
    azurerm_role_assignment.agw_kv_secrets_user,
    azurerm_role_assignment.agw_kv_certificate_user,
  ]
}
