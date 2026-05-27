resource "kubectl_manifest" "gp3" {
  yaml_body = <<-YAML
    apiVersion: storage.k8s.io/v1
    kind: StorageClass
    metadata:
      name: gp3
    provisioner: ebs.csi.aws.com
    parameters:
      type: gp3
      fsType: ext4

      # Free baseline performance (no extra cost)
      iops: "3000"
      throughput: "125"
      encrypted: "true"

    reclaimPolicy: Delete
    volumeBindingMode: WaitForFirstConsumer
    allowVolumeExpansion: true
  YAML
}