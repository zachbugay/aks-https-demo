output "AZURE_RESOURCE_GROUP" {
  value = azurerm_resource_group.rg.name
}

output "AZURE_LOCATION" {
  value = azurerm_resource_group.rg.location
}

output "AZURE_AKS_CLUSTER_NAME" {
  value = azurerm_kubernetes_cluster.aks.name
}

output "KEY_VAULT_NAME" {
  value = azurerm_key_vault.kv.name
}

output "TLS_CERT_NAME" {
  value = azurerm_key_vault_certificate.frontend_cert.name
}

output "AGW_NAME" {
  value = azurerm_application_gateway.agw.name
}

output "AGW_PUBLIC_IP" {
  value = azurerm_public_ip.agw.ip_address
}

output "K8S_GATEWAY_INTERNAL_IP" {
  value = var.k8s_gateway_internal_ip
}
