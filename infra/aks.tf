#### AKS

# Identity for the managed cluster
resource "azurerm_user_assigned_identity" "aks-identity" {
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  name                = "uami-aks-${local.name}"
  tags                = local.common_tags
}

# Identity for the kubelet, used to pull images from ACR for example
resource "azurerm_user_assigned_identity" "kubelet_identity" {
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  name                = "uami-aks-kubelet-${local.name}"
  tags                = local.common_tags
}

resource "azurerm_role_assignment" "managed_identity_operator" {
  principal_id         = azurerm_user_assigned_identity.aks-identity.principal_id
  scope                = azurerm_user_assigned_identity.kubelet_identity.id
  role_definition_name = "Managed Identity Operator"
}

resource "azurerm_role_assignment" "network_contributor" {
  principal_id         = azurerm_user_assigned_identity.aks-identity.principal_id
  scope                = azurerm_subnet.snet-aks.id
  role_definition_name = "Network Contributor"
}

resource "azurerm_kubernetes_cluster" "aks" {
  name                = "aks-${local.name}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = "aks-${local.name}"

  kubernetes_version = "1.36.1"

  default_node_pool {
    name                 = "syspool1"
    node_count           = 1
    vm_size              = "Standard_D2as_v7"
    os_sku               = "AzureLinux"
    vnet_subnet_id       = azurerm_subnet.snet-aks.id
    auto_scaling_enabled = true
    min_count            = 1
    max_count            = 5
    max_pods             = 64

    upgrade_settings {
      max_surge = "33%"
    }
  }

  automatic_upgrade_channel = "rapid"

  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  api_server_access_profile {
    authorized_ip_ranges = concat(
      ["${chomp(data.http.current_ip.response_body)}/32"],
      tolist(azurerm_virtual_network.vnet.address_space)
    )
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks-identity.id]
  }

  kubelet_identity {
    client_id                 = azurerm_user_assigned_identity.kubelet_identity.client_id
    object_id                 = azurerm_user_assigned_identity.kubelet_identity.principal_id
    user_assigned_identity_id = azurerm_user_assigned_identity.kubelet_identity.id
  }

  azure_active_directory_role_based_access_control {
    tenant_id              = data.azurerm_client_config.current.tenant_id
    admin_group_object_ids = var.admin_group_object_ids
    azure_rbac_enabled     = true
  }

  network_profile {
    network_plugin      = "azure"
    network_policy      = "cilium"
    network_data_plane  = "cilium"
    network_plugin_mode = "overlay"
    outbound_type       = "loadBalancer"
    load_balancer_sku   = "standard"
    service_cidr        = "10.233.0.0/16"
    dns_service_ip      = "10.233.0.10"

    advanced_networking {
      observability_enabled = true
      security_enabled      = true
    }
  }

  oms_agent {
    log_analytics_workspace_id      = azurerm_log_analytics_workspace.law.id
    msi_auth_for_monitoring_enabled = true
  }

  monitor_metrics {
    # annotations_allowed = ""
    # labels_allowed = ""
  }

  web_app_routing {
    dns_zone_ids = []
  }

  sku_tier = "Free"

  tags = local.common_tags

  lifecycle {
    ignore_changes = [
      default_node_pool[0].node_count,
      web_app_routing,
      microsoft_defender
    ]
  }
}

# Enable AKS addons
resource "azapi_update_resource" "aks_addons" {
  type        = "Microsoft.ContainerService/managedClusters@2026-04-02-preview"
  resource_id = azurerm_kubernetes_cluster.aks.id

  body = {
    properties = merge(
      {
        ingressProfile = {
          gatewayAPI = {
            installation = "Standard"
          }
          webAppRouting = {
            enabled = true
            gatewayAPIImplementations = {
              appRoutingIstio = {
                mode = "Enabled"
              }
            }
          }
        }
      },
      var.enable_cilium_mtls ? {
        networkProfile = {
          advancedNetworking = {
            security = {
              transitEncryption = {
                type = "mTLS"
              }
            }
          }
        }
      } : {}
    )
  }
}

# TODO: For now, this is going to federate into the default namespace. Figure out a better way.
resource "azurerm_federated_identity_credential" "fic_kubelet" {
  name                      = "fc-${azurerm_user_assigned_identity.kubelet_identity.name}"
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azurerm_kubernetes_cluster.aks.oidc_issuer_url
  user_assigned_identity_id = azurerm_user_assigned_identity.kubelet_identity.id
  subject                   = "system:serviceaccount:default:${azurerm_user_assigned_identity.kubelet_identity.name}"
}

resource "azurerm_role_assignment" "aks_rbac_cluster_admin_deployer" {
  scope                = azurerm_kubernetes_cluster.aks.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}
