variable "kubeconfig_path" {
  description = "Path to kubeconfig file"
  type        = string
  default     = "~/.kube/config"
}

variable "namespace" {
  description = "Namespace to deploy into"
  type        = string
  default     = "default"
}

variable "replica_count" {
  description = "Number of pod replicas"
  type        = number
  default     = 1
}

variable "image_repository" {
  description = "Container image repository"
  type        = string
  default     = "learnkube"
}

variable "image_tag" {
  description = "Container image tag / app version"
  type        = string
  default     = "v1"
}
