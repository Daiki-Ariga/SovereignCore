# Manually Registering Tenant Storage

This guide explains how to manually create a tenant-specific StorageClass directly on the VM cluster.

## Overview

When using a storage provider other than Ceph, create the StorageClass directly on the VM cluster following the naming convention below. Once the StorageClass exists on the cluster, VMaaS will use it automatically when provisioning DataVolumes for the tenant.

## StorageClass Naming Convention

StorageClass names must follow this pattern:

```
{storageclass-name}-{ofAccount}
```

Where:
- `{storageclass-name}` — a descriptive name reflecting the provider and use case (e.g., `portworx-block`, `nfs-rwx`)
- `{ofAccount}` — the tenant identifier (also referred to as `accountId`)

**Example**: if `ofAccount` is `tenant-a` and the StorageClass name is `portworx-block`, the resulting StorageClass on the cluster must be named `portworx-block-tenant-a`.

Choose names that are unique and descriptive to avoid collisions across tenants and providers.

## Creating a StorageClass on the VM Cluster

Apply a StorageClass manifest directly to the VM cluster using the naming convention above.

### Template

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: <storageclass-name>-<ofAccount>
provisioner: <csi-driver-name>
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
parameters:
  <param-key>: <param-value>
```

```bash
oc apply -f storageclass.yaml --context <target-cluster>
```

### Provider Examples

#### Portworx

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: portworx-block-tenant-a
provisioner: pxd.portworx.com
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
parameters:
  repl: "2"
  io_profile: db_remote
```

#### NFS (ReadWriteMany)

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-rwx-tenant-a
provisioner: nfs.csi.k8s.io
reclaimPolicy: Delete
volumeBindingMode: Immediate
parameters:
  server: <nfs-server-ip>
  share: /exports/tenant-a
```

Refer to your storage provider's CSI driver documentation for the required `provisioner` value and StorageClass parameters.

## Verification

Confirm the StorageClass is present on the cluster:

```bash
oc get storageclass --context <target-cluster> | grep <ofAccount>
```

Expected output:

```
portworx-block-tenant-a   pxd.portworx.com   Delete   WaitForFirstConsumer   false   1m
```

## Platform Fallback (Testing Only)

When `STORAGE_FALLBACK_ENABLED=true` is set on the VMaaS operator **and** no matching StorageClass exists for the tenant, the operator falls back to a statically configured platform StorageClass.

**This flag is disabled by default and must not be enabled in production.** It is intended for development environments where tenant storage is not yet configured.

| Priority | Source |
|----------|--------|
| 1 | `VMInstanceConfig.StorageClass` (operator config) |
| 2 | StorageClass annotated `storageclass.kubevirt.io/is-default-virt-class: "true"` |
| 3 | StorageClass annotated `storageclass.kubernetes.io/is-default-class: "true"` |

## Troubleshooting

### DataVolume fails to provision

The StorageClass name may not match the expected convention.

- Verify the StorageClass name exactly follows `{storageclass-name}-{ofAccount}` (case-sensitive)
- Check that the StorageClass is present on the correct cluster:

```bash
oc get storageclass --context <target-cluster>
```

### StorageClass exists but DataVolume is stuck pending

The CSI driver may not be healthy or the `volumeBindingMode` may not be appropriate for the workload.

- Check the CSI driver pods: `oc get pods -n <csi-driver-namespace> --context <target-cluster>`
- Review the DataVolume events: `oc describe datavolume <name> -n <tenant-namespace> --context <target-cluster>`

## Best Practices

1. **Follow the naming convention exactly** — VMaaS selects the StorageClass by the `{storageclass-name}-{ofAccount}` pattern; an incorrect name means the StorageClass will not be found
2. **Use descriptive provider prefixes** — choose names like `portworx-block` or `nfs-rwx` rather than generic names to avoid collisions across tenants
3. **Set `volumeBindingMode: WaitForFirstConsumer`** where supported — this ensures volumes are provisioned in the same availability zone as the VM
4. **Apply to the correct cluster** — always target the specific VM cluster context using `--context <target-cluster>`
