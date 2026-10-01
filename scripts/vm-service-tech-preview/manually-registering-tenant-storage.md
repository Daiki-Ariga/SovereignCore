# Manually Registering Tenant Storage

This guide explains how to manually create a tenant-specific StorageClass directly on the VM cluster for storage providers other than Ceph.

## Overview

Guest OS storage for VMs is provisioned through StorageClass resources on the VM cluster. When using a storage provider other than Ceph, create the StorageClass directly on the VM cluster following the naming convention below.

VMaaS resolves the StorageClass for a tenant by querying `StorageRegistration` resources on the Hub cluster (filtered by the tenant's `accountId`). It derives the StorageClass name from each registered resource using the pattern `{resourceName}-{accountId}`, then expects a StorageClass with that name to exist on the VM cluster. Once a matching StorageClass is present, VMaaS uses it when provisioning DataVolumes for the tenant.

**Important**: These resources should be applied directly to the VM cluster where OpenShift Virtualization is installed, not the Hub cluster.

## Prerequisites

- A CSI driver for your storage provider installed and running on the VM cluster
- Access to the VM cluster with permissions to create StorageClass resources
- The `accountId` (tenant identifier) for the tenant you are configuring
- `oc` CLI configured to access the VM cluster

## StorageClass Naming Convention

StorageClass names must follow this pattern:

```
{storageclass-name}-{account-id}
```

Where:
- `{storageclass-name}` — a descriptive name reflecting the provider and use case (e.g., `portworx-block`, `nfs-rwx`). This value is free-form but must comply with Kubernetes DNS subdomain naming rules: lowercase alphanumeric characters and hyphens only, starting and ending with an alphanumeric character, and no more than 253 characters in total (including the `-{account-id}` suffix).
- `{account-id}` — the tenant `accountId`

**Example**: if `accountId` is `tenant-a` and the StorageClass name is `portworx-block`, the resulting StorageClass on the cluster must be named `portworx-block-tenant-a`.

Choose names that are unique and descriptive to avoid collisions across tenants and providers.

## Adding a StorageClass for a Tenant

### Step 1: Create the StorageClass YAML

Create a YAML file (e.g., `storageclass.yaml`) using the naming convention above:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: <storageclass-name>-<account-id>
provisioner: <csi-driver-name>
reclaimPolicy: Delete   # PVC deletion will permanently delete the underlying volume
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true   # Set to true if the CSI driver supports volume expansion
parameters:
  <param-key>: <param-value>
```

### Step 2: Apply to the VM Cluster

Apply the StorageClass manifest directly to the VM cluster:

```bash
oc apply -f storageclass.yaml --context <target-cluster>
```

## Configuration Parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| `metadata.name` | Must follow `{storageclass-name}-{account-id}` — case-sensitive | `portworx-block-tenant-a` |
| `provisioner` | CSI driver name for the storage provider | `pxd.portworx.com` |
| `reclaimPolicy` | Volume reclaim policy | `Delete` |
| `volumeBindingMode` | Use `WaitForFirstConsumer` where supported; `Immediate` for drivers that do not support topology-aware provisioning (e.g., NFS) | `WaitForFirstConsumer` |
| `allowVolumeExpansion` | Set to `true` if the CSI driver supports online volume expansion; omit or set to `false` otherwise | `true` |
| `parameters` | Provider-specific CSI driver parameters | `repl: "2"` |

## Complete Example: Adding Portworx Storage for a Tenant

1. **Create `portworx-block-tenant-a.yaml`** (see the [Portworx provider example](#portworx) below for the full YAML).

2. **Apply to the VM cluster:**

```bash
oc apply -f portworx-block-tenant-a.yaml --context <target-cluster>
```

3. **Verify** — see the [Verification](#verification) section for detailed steps.

## Provider Examples

### Portworx

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: portworx-block-tenant-a
provisioner: pxd.portworx.com
reclaimPolicy: Delete   # PVC deletion will permanently delete the underlying volume
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
parameters:
  repl: "2"
  io_profile: db_remote
```

### NFS (ReadWriteMany)

NFS uses `volumeBindingMode: Immediate` because the NFS CSI driver does not support topology-aware provisioning.

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-rwx-tenant-a
provisioner: nfs.csi.k8s.io
reclaimPolicy: Delete   # PVC deletion will permanently delete the underlying volume
volumeBindingMode: Immediate
# allowVolumeExpansion is omitted — the NFS CSI driver does not support online volume expansion
parameters:
  server: <nfs-server-ip>
  share: /exports/tenant-a
```

Refer to your storage provider's CSI driver documentation for the required `provisioner` value and StorageClass parameters.

## Verification

After applying the StorageClass resource:

1. **Confirm the StorageClass is present:**
```bash
oc get storageclass --context <target-cluster> | grep <account-id>
```

2. **Inspect the StorageClass details:**
```bash
oc describe storageclass <storageclass-name>-<account-id> --context <target-cluster>
```

3. **Check the CSI driver is healthy:**
```bash
oc get pods -n <csi-driver-namespace> --context <target-cluster>
```

## Platform Fallback (Testing Only)

When `STORAGE_ALLOW_PLATFORM_FALLBACK=true` is set on the VMaaS operator **and** no `StorageRegistration` resource is found on the Hub for the tenant, the operator skips the storage delivery flow and provisions the VM using the static platform StorageClass configured via `VMInstanceConfig.StorageClass` (env var `VMINSTANCE_STORAGE_CLASS`).

**This flag is disabled by default and must not be enabled in production.** It is intended for development environments where tenant storage is not yet configured.

## Troubleshooting

### DataVolume fails to provision

The StorageClass name may not match the expected convention.

- Verify the StorageClass name exactly follows `{storageclass-name}-{account-id}` (case-sensitive)
- Check that the StorageClass is present on the correct cluster:
```bash
oc get storageclass --context <target-cluster>
```

### StorageClass exists but DataVolume is stuck pending

The CSI driver may not be healthy or the `volumeBindingMode` may not be appropriate for the workload.

- Check the CSI driver pods: `oc get pods -n <csi-driver-namespace> --context <target-cluster>`
- Review the DataVolume events: `oc describe datavolume <name> -n <tenant-namespace> --context <target-cluster>`

### Permission issues

- Verify you have permissions to create StorageClass resources on the VM cluster
- Check RBAC: `oc auth can-i create storageclass --context <target-cluster>`

## Best Practices

1. **Follow the naming convention exactly** — VMaaS selects the StorageClass by the `{storageclass-name}-{account-id}` pattern; an incorrect name means the StorageClass will not be found
2. **Use descriptive provider prefixes** — choose names like `portworx-block` or `nfs-rwx` rather than generic names to avoid collisions across tenants and providers
3. **Set `volumeBindingMode: WaitForFirstConsumer`** where supported — this ensures volumes are provisioned in the same availability zone as the VM; use `Immediate` only when the CSI driver does not support topology-aware provisioning (e.g., NFS)
4. **Apply to the correct cluster** — always target the specific VM cluster context using `--context <target-cluster>`
5. **Test new StorageClasses** in a development cluster before applying to production

## Related Resources

- [Kubernetes StorageClass documentation](https://kubernetes.io/docs/concepts/storage/storage-classes/)
- [OpenShift Virtualization Documentation](https://docs.openshift.com/container-platform/latest/virt/about-virt.html)
