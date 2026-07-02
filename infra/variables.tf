variable "environment" {
  description = "Environment name, such as dev, qa, prod."
  type        = string
}

variable "location" {
  description = "Azure region to deploy resources."
  type        = string
}

variable "workload_name" {
  description = "Unique identifier for the workload being deployed."
  type        = string
}

variable "admin_group_object_ids" {
  description = "(Optional) List of Microsoft Entra group object IDs that will have admin role of the cluster."
  type        = set(string)
  default     = []
}

variable "k8s_gateway_internal_ip" {
  description = "Static internal IP for the Kubernetes (Istio) Gateway load balancer, used as the App Gateway backend target."
  type        = string
  default     = "10.0.3.240"
}

variable "httpbin_hostname" {
  description = "Public hostname for the httpbin app. Must resolve to the App Gateway public IP."
  type        = string
}

variable "podinfo_hostname" {
  description = "Public hostname for the podinfo app. Must resolve to the App Gateway public IP."
  type        = string
}

variable "enable_cilium_mtls" {
  description = "Enable Cilium mTLS"
  type        = bool
  default     = false
}

