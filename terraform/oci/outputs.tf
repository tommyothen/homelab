# terraform/oci/outputs.tf

output "hephaestus_ip" {
  description = "Public IP of the Hephaestus instance (game servers)"
  value       = oci_core_instance.hephaestus.public_ip
}

output "tartarus_ip" {
  description = "Public IP of the Tartarus instance (off-site backup)"
  value       = oci_core_instance.tartarus.public_ip
}

output "image_id" {
  description = "OCID of the imported NixOS image"
  value       = oci_core_image.nixos.id
}
