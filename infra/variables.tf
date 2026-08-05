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

variable "appgw_applications" {
  description = <<-EOT
    Applications published through the Application Gateway. Each entry generates a health probe,
    backend HTTP settings, an HTTPS listener, an HTTP listener, an HTTPS routing rule, and an
    HTTP-to-HTTPS redirect. The map key is the application name and is used to build resource names.
    `hostname` may be left null to fall back to the matching `<key>_hostname` variable.

    `rule_type` applies to the application's HTTPS routing rule. When it is `PathBasedRouting`,
    `path_rules` must be populated and a URL path map is generated for the application; unmatched
    paths fall through to the application's own backend HTTP settings. Each path rule may target a
    different application's backend HTTP settings via `backend_app`. The HTTP-to-HTTPS redirect rule
    is always `Basic`, since it redirects every path to the HTTPS listener.

    `https_port` and `http_port` are gateway wide: the Application Gateway exposes a single shared
    `https-port` and `http-port` frontend port, so every application must declare the same values.
  EOT

  type = map(object({
    hostname                  = optional(string)
    https_port                = optional(number, 443)
    http_port                 = optional(number, 80)
    probe_path                = string
    probe_protocol            = optional(string, "Https")
    probe_interval            = optional(number, 30)
    probe_timeout             = optional(number, 30)
    probe_unhealthy_threshold = optional(number, 3)
    probe_status_codes        = optional(list(string), ["200-399"])
    backend_port              = optional(number, 443)
    backend_protocol          = optional(string, "Https")
    backend_request_timeout   = optional(number, 30)
    cookie_based_affinity     = optional(string, "Disabled")
    rule_type                 = optional(string, "Basic")
    redirect_type             = optional(string, "Permanent")
    path_rules = optional(list(object({
      name        = string
      paths       = list(string)
      backend_app = optional(string)
    })), [])
    https_rule_priority         = number
    http_redirect_rule_priority = number
  }))

  default = {
    httpbin = {
      https_port                  = 443
      http_port                   = 80
      probe_path                  = "/get"
      probe_protocol              = "Https"
      probe_interval              = 30
      probe_timeout               = 30
      probe_unhealthy_threshold   = 3
      probe_status_codes          = ["200-399"]
      backend_port                = 443
      backend_protocol            = "Https"
      backend_request_timeout     = 30
      cookie_based_affinity       = "Disabled"
      rule_type                   = "Basic"
      redirect_type               = "Permanent"
      path_rules                  = []
      https_rule_priority         = 100
      http_redirect_rule_priority = 90
    }
    podinfo = {
      https_port                  = 443
      http_port                   = 80
      probe_path                  = "/healthz"
      probe_protocol              = "Https"
      probe_interval              = 30
      probe_timeout               = 30
      probe_unhealthy_threshold   = 3
      probe_status_codes          = ["200-399"]
      backend_port                = 443
      backend_protocol            = "Https"
      backend_request_timeout     = 30
      cookie_based_affinity       = "Disabled"
      rule_type                   = "Basic"
      redirect_type               = "Permanent"
      path_rules                  = []
      https_rule_priority         = 110
      http_redirect_rule_priority = 80
    }
  }

  validation {
    condition     = length(var.appgw_applications) > 0
    error_message = "At least one application must be defined in appgw_applications."
  }

  validation {
    condition = alltrue(flatten([
      for app in var.appgw_applications : [
        for port in [app.https_port, app.http_port] : port >= 1 && port <= 65535
      ]
    ]))
    error_message = "Frontend ports must be between 1 and 65535."
  }

  validation {
    condition = alltrue([
      for app in var.appgw_applications : app.https_port != app.http_port
    ])
    error_message = "The HTTPS and HTTP frontend ports must be different."
  }

  validation {
    condition = length(distinct([
      for app in var.appgw_applications : [app.https_port, app.http_port]
    ])) <= 1
    error_message = "The Application Gateway exposes one shared frontend port pair, so every application must declare the same https_port and http_port."
  }

  validation {
    condition = alltrue([
      for app in var.appgw_applications : contains(["Basic", "PathBasedRouting"], app.rule_type)
    ])
    error_message = "rule_type must be one of: Basic, PathBasedRouting."
  }

  validation {
    condition = alltrue([
      for app in var.appgw_applications :
      contains(["Permanent", "Temporary", "Found", "SeeOther"], app.redirect_type)
    ])
    error_message = "redirect_type must be one of: Permanent, Temporary, Found, SeeOther."
  }

  validation {
    condition = alltrue([
      for app in var.appgw_applications :
      length(app.path_rules) > 0 if app.rule_type == "PathBasedRouting"
    ])
    error_message = "Applications with rule_type PathBasedRouting must define at least one entry in path_rules."
  }

  validation {
    condition = alltrue([
      for app in var.appgw_applications :
      length(app.path_rules) == 0 if app.rule_type != "PathBasedRouting"
    ])
    error_message = "path_rules may only be set when rule_type is PathBasedRouting."
  }

  validation {
    condition = alltrue([
      for app in var.appgw_applications :
      length(distinct([for rule in app.path_rules : rule.name])) == length(app.path_rules)
    ])
    error_message = "Path rule names must be unique within an application."
  }

  validation {
    condition = alltrue(flatten([
      for app in var.appgw_applications : [
        for rule in app.path_rules : length(rule.paths) > 0 && alltrue([
          for path in rule.paths : startswith(path, "/")
        ])
      ]
    ]))
    error_message = "Every path rule must declare at least one path, and each path must start with \"/\"."
  }

  validation {
    condition = alltrue(flatten([
      for app in var.appgw_applications : [
        for rule in app.path_rules :
        contains(keys(var.appgw_applications), rule.backend_app) if rule.backend_app != null
      ]
    ]))
    error_message = "Each path rule backend_app must reference a key defined in appgw_applications."
  }

  validation {
    condition = length(distinct(flatten([
      for app in var.appgw_applications : [app.https_rule_priority, app.http_redirect_rule_priority]
    ]))) == length(var.appgw_applications) * 2
    error_message = "Every routing rule priority in appgw_applications must be unique."
  }

  validation {
    condition = alltrue(flatten([
      for app in var.appgw_applications : [
        for priority in [app.https_rule_priority, app.http_redirect_rule_priority] :
        priority >= 1 && priority <= 20000
      ]
    ]))
    error_message = "Routing rule priorities must be between 1 and 20000."
  }
}

variable "enable_cilium_mtls" {
  description = "Enable Cilium mTLS"
  type        = bool
  default     = false
}

