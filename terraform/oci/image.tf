# terraform/oci/image.tf

# Upload the qcow2 to Object Storage
resource "oci_objectstorage_object" "nixos_image" {
  bucket    = "nixos-images"
  namespace = var.namespace
  object    = "nixos-aarch64.qcow2"
  source    = var.image_path
}

# Import as a custom OCI image
resource "oci_core_image" "nixos" {
  compartment_id = var.compartment_ocid
  display_name   = "NixOS ARM64 Bootstrap"

  image_source_details {
    source_type    = "objectStorageTuple"
    namespace_name = var.namespace
    bucket_name    = "nixos-images"
    object_name    = oci_objectstorage_object.nixos_image.object
  }

  launch_mode = "PARAVIRTUALIZED"

  timeouts {
    create = "60m"
  }
}

# Register shape compatibility for A1.Flex
resource "oci_core_shape_management" "nixos_a1_compat" {
  compartment_id = var.compartment_ocid
  image_id       = oci_core_image.nixos.id
  shape_name     = "VM.Standard.A1.Flex"

  depends_on = [oci_core_image.nixos]
}

# Look up the latest global image capability schema version dynamically
# (avoids hardcoding a UUID that could change if Oracle updates the schema)
data "oci_core_compute_global_image_capability_schemas" "all" {}

data "oci_core_compute_global_image_capability_schemas_versions" "latest" {
  compute_global_image_capability_schema_id = data.oci_core_compute_global_image_capability_schemas.all.compute_global_image_capability_schemas[0].id
}

# Set image capabilities (UEFI, paravirtualized)
resource "oci_core_compute_image_capability_schema" "nixos_caps" {
  compartment_id                                      = var.compartment_ocid
  image_id                                            = oci_core_image.nixos.id
  compute_global_image_capability_schema_version_name = data.oci_core_compute_global_image_capability_schemas_versions.latest.compute_global_image_capability_schema_versions[0].name

  schema_data = {
    "Compute.Firmware" = jsonencode({
      descriptorType = "enumstring"
      source         = "IMAGE"
      defaultValue   = "UEFI_64"
      values         = ["UEFI_64"]
    })

    "Compute.LaunchMode" = jsonencode({
      descriptorType = "enumstring"
      source         = "IMAGE"
      defaultValue   = "PARAVIRTUALIZED"
      values         = ["PARAVIRTUALIZED", "EMULATED", "CUSTOM", "NATIVE"]
    })

    "Storage.BootVolumeType" = jsonencode({
      descriptorType = "enumstring"
      source         = "IMAGE"
      defaultValue   = "PARAVIRTUALIZED"
      values         = ["PARAVIRTUALIZED", "ISCSI", "SCSI", "IDE"]
    })

    "Network.AttachmentType" = jsonencode({
      descriptorType = "enumstring"
      source         = "IMAGE"
      defaultValue   = "PARAVIRTUALIZED"
      values         = ["PARAVIRTUALIZED", "E1000", "VFIO"]
    })
  }
}
