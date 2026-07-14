output "release_name" {
  value = helm_release.learnkube.name
}

output "release_status" {
  value = helm_release.learnkube.status
}
