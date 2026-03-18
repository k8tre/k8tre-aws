# Standard storage classes required by K8TRE

resource "kubernetes_storage_class" "rwo-default" {
  metadata {
    name = "rwo-default"
    annotations = {
      "description" = "ReadWriteOnce - Single pod read-write access"
    }
  }
  storage_provisioner = "kubernetes.io/aws-ebs"
  reclaim_policy      = "Delete"
  parameters = {
    type = "gp3"
  }
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  provider = kubernetes.k8tre-dev
}

data "aws_efs_file_system" "lookup" {
  creation_token = data.terraform_remote_state.k8tre.outputs.efs_token
}

# https://github.com/kubernetes-sigs/aws-efs-csi-driver/blob/ada97c0de28ddea1b525595ed419292191c8601d/examples/kubernetes/dynamic_provisioning/README.md
resource "kubernetes_storage_class" "rwx-default" {
  metadata {
    name = "rwx-default"
    annotations = {
      "description" = "ReadWriteMany - Multi-pod shared read-write access"
    }
  }
  storage_provisioner = "efs.csi.aws.com"
  reclaim_policy      = "Delete"
  parameters = {
    provisioningMode = "efs-ap"
    fileSystemId     = data.aws_efs_file_system.lookup.id
    directoryPerms   = "750"

    # The rest of these are optional
    gidRangeStart         = "1000"
    gidRangeEnd           = "2000"
    basePath              = "/dynamic_provisioning"
    subPathPattern        = "$${.PVC.namespace}/$${.PVC.name}"
    ensureUniqueDirectory = "true"
    reuseAccessPoint      = "false"
  }
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  provider = kubernetes.k8tre-dev
}

