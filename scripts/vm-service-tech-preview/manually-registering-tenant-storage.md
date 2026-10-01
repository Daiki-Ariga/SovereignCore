# Manually Registering Tenant Storage

This guide explains how to manually register a tenant-specific StorageClass and deliver it to a managed cluster using the `sov-core-storage` API.

## Overview

Tenant storage is configured in two steps:

1. **Storage Registration** — Register the tenant's storage resources (StorageClass, Secrets, etc.) on the Hub cluster via `POST /internal/v1/storage-registrations`.
2. **Storage Delivery** — Propagate the registered resources to the target managed cluster via `POST /internal/v1/storage-delivery-requests`.

These two steps are independent. Registration is a one-time setup per tenant × provider combination. Delivery can be triggered multiple times (e.g., for different target clusters).

**Important**: The `provider` field must always be specified explicitly. If omitted, the API defaults to `ceph`. This means a registration intended for a non-Ceph provider (e.g., Portworx) will be silently created as `{ofAccount}-ceph` instead of `{ofAccount}-portworx`.

## Prerequisites

- Access to the `sov-core-storage` REST API (typically `https://<hub>/internal/v1`)
- A valid MCSP bearer token with MSP Operator permissions
- The target managed cluster must be registered with ACM and belong to the correct ClusterSet
- `curl` or equivalent HTTP client

## StorageClass Naming Convention

The StorageClass name that VMaaS selects for a DataVolume is derived as:

```
{resource.metadata.name}-{ofAccount}
```

For example, if `ofAccount` is `tenant-a` and the StorageClass resource name is `ceph-rbd`, the resulting StorageClass on the managed cluster will be named `ceph-rbd-tenant-a`.

**Ensure the resource name reflects the provider and use case** (e.g., `ceph-rbd`, `portworx-block`) to avoid naming collisions across tenants.

## Parameters

### POST /internal/v1/storage-registrations

| Parameter | Description | Example |
|-----------|-------------|---------|
| `ofAccount` | Tenant identifier (also referred to as `accountId`) | `tenant-a` |
| `provider` | Storage provider identifier. Defaults to `ceph` if omitted — always specify explicitly | `ceph` |
| `providerConfig.type` | Ceph only. Ceph connection type | `external` |
| `providerConfig.version` | Ceph only. ODF version | `4.19` |
| `providerConfig.clusterID` | Ceph only. Ceph cluster namespace | `openshift-storage` |
| `resources[].name` | StorageClass resource name. Becomes the prefix of the final StorageClass name on the managed cluster (`{name}-{ofAccount}`) | `ceph-rbd` |
| `resources[].kind` | Resource type. Currently only `StorageClass` is supported | `StorageClass` |
| `resources[].data.provisioner` | CSI driver name for the StorageClass | `rbd.csi.ceph.com` |
| `resources[].data.*` | Additional StorageClass parameters required by the CSI driver | `pool`, `repl`, etc. |

### POST /internal/v1/storage-delivery-requests

| Parameter | Description | Example |
|-----------|-------------|---------|
| `ofAccount` | Tenant identifier | `tenant-a` |
| `clusterSelector.matchLabels` | Labels used to select the target managed cluster(s). Always specify to avoid unintended delivery | `{"name": "cluster-1"}` |
| `provider` | Optional. Limit delivery to a single provider's StorageRegistration. If omitted, all registrations for the tenant are delivered | `ceph` |

## Step 1: Register Tenant Storage

### Request

```bash
curl -X POST https://<hub>/internal/v1/storage-registrations \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -d '{
    "ofAccount": "<tenant-id>",
    "provider": "<provider>",
    "providerConfig": {
      "type": "external",
      "version": "4.19",
      "clusterID": "openshift-storage"
    },
    "resources": [
      {
        "name": "<storageclass-name>",
        "kind": "StorageClass",
        "data": {
          "provisioner": "<csi-provisioner>"
        }
      }
    ]
  }'
```

### Response (201 Created)

```json
{
  "storageRegistrationName": "<tenant-id>-<provider>",
  "namespace": "sov-core-storage",
  "secretsCreated": [],
  "status": "created"
}
```

The `storageRegistrationName` follows the format `{ofAccount}-{provider}`. Re-invoking with the same `ofAccount` × `provider` combination performs an upsert (safe to call multiple times).

## Step 2: Deliver Storage to a Managed Cluster

### Request

```bash
curl -X POST https://<hub>/internal/v1/storage-delivery-requests \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -d '{
    "ofAccount": "<tenant-id>",
    "clusterSelector": {
      "matchLabels": {
        "name": "<target-cluster-name>"
      }
    }
  }'
```

> **Note**: The `provider` field is omitted intentionally — all StorageRegistrations for the tenant are delivered in a single batch. To deliver only a specific provider, add `"provider": "<provider>"` to the request body.

### Response (201 Created)

```json
{
  "requestId": "batch-<uuid>",
  "storageDeliveryRequests": [
    {
      "storageDeliveryRequestName": "<uuid>",
      "provider": "<provider>",
      "namespace": "sov-core-storage",
      "status": "created"
    }
  ]
}
```

Save the `requestId` to poll delivery status in Step 3.

## Step 3: Verify Delivery

Poll the batch status until `overallPhase` is `Ready`:

```bash
curl "https://<hub>/internal/v1/storage-delivery-requests/<requestId>/status?ofAccount=<tenant-id>" \
  -H "Authorization: Bearer <token>"
```

### Response

```json
{
  "requestId": "batch-<uuid>",
  "overallPhase": "Ready",
  "storageDeliveryRequests": [
    {
      "storageDeliveryRequestName": "<uuid>",
      "provider": "<provider>",
      "phase": "Ready",
      "propagationStatus": "Propagated",
      "lastReconcileTime": "2024-01-01T00:00:00Z"
    }
  ]
}
```

`overallPhase: "Ready"` means every item has both `phase: Ready` (Hub-side) **and** `propagationStatus: Propagated` (managed cluster). `phase: Ready` alone is not sufficient.

## Provider-Specific Examples

The `resources[].data` fields vary by provider. The API structure, request shape, and all steps are identical regardless of provider. Set `provisioner` and any additional parameters according to your storage provider's documentation.

### Ceph RBD (reference example)

> **Note**: Ceph is the only provider currently implemented in the controller. Registrations for other providers are accepted by the API but will result in `Phase: Failed` until controller support is added.

```json
{
  "ofAccount": "tenant-a",
  "provider": "ceph",
  "providerConfig": {
    "type": "external",
    "version": "4.19",
    "clusterID": "openshift-storage"
  },
  "resources": [
    {
      "name": "ceph-rbd",
      "kind": "StorageClass",
      "data": {
        "provisioner": "rbd.csi.ceph.com",
        "pool": "rbd-pool"
      }
    }
  ]
}
```

Resulting StorageClass name on the managed cluster: `ceph-rbd-tenant-a`

### Other Providers

For any other CSI-compatible storage provider, use the same request structure — set `provider` to a descriptive identifier and populate `resources[].data` with the fields required by that provider's CSI driver:

```json
{
  "ofAccount": "<tenant-id>",
  "provider": "<provider-identifier>",
  "resources": [
    {
      "name": "<descriptive-storageclass-name>",
      "kind": "StorageClass",
      "data": {
        "provisioner": "<csi-driver-name>",
        "<param-key>": "<param-value>"
      }
    }
  ]
}
```

Refer to your storage provider's CSI driver documentation for the required `provisioner` value and StorageClass parameters.

## Platform Fallback (Testing Only)

When `STORAGE_FALLBACK_ENABLED=true` is set on the VMaaS operator **and** no `StorageRegistration` exists for the tenant, the operator skips storage delivery and falls back to a statically configured platform StorageClass.

**This flag is disabled by default and must not be enabled in production.** It is intended for development environments where tenant storage is not yet configured.

| Priority | Source |
|----------|--------|
| 1 | `VMInstanceConfig.StorageClass` (operator config) |
| 2 | StorageClass annotated `storageclass.kubevirt.io/is-default-virt-class: "true"` |
| 3 | StorageClass annotated `storageclass.kubernetes.io/is-default-class: "true"` |

## Verification on the Hub Cluster

Check the StorageRegistration CR status directly:

```bash
# List all StorageRegistrations for a tenant
kubectl get storagereg -n sov-core-storage -l storage.sovereign.cloud.ibm.com/account=<tenant-id>

# Inspect a specific registration
kubectl describe storagereg <tenant-id>-<provider> -n sov-core-storage
```

Check the StorageDeliveryRequest CR:

```bash
kubectl get storagedeliveryrequest -n sov-core-storage -l storage.sovereign.cloud.ibm.com/account=<tenant-id>
```

Verify the StorageClass was propagated to the managed cluster:

```bash
oc get storageclass --context <target-cluster> | grep <tenant-id>
```

## Troubleshooting

### HTTP 404 on Delivery Request

The `StorageRegistration` for the tenant does not exist, or `provider` was specified but no matching registration was found.

- Verify registration exists: `kubectl get storagereg -n sov-core-storage`
- Confirm `ofAccount` and `provider` match exactly (case-sensitive)
- If `provider` was omitted during registration, the CR name defaults to `{ofAccount}-ceph`

### StorageRegistration Phase: Failed

The controller could not process the registration.

```bash
kubectl describe storagereg <name> -n sov-core-storage
```

Check the `conditions` field for the error reason. Common causes:
- Provider not implemented in the controller (e.g., `portworx` — currently only `ceph` is supported)
- Referenced Secrets not found in the `sov-core-storage` namespace

### overallPhase: Processing (not progressing)

- Check ACM Policy propagation: `kubectl get policy -n sov-core-storage`
- Verify the target cluster is online and reachable by ACM
- Check the `propagationStatus` per item — `Unknown` usually means ACM has not yet evaluated the policy

### overallPhase: Failed

```bash
# Check the StorageDeliveryRequest status
kubectl describe storagedeliveryrequest <name> -n sov-core-storage

# Check ACM Policy compliance
kubectl get policy -n sov-core-storage
kubectl describe policy <policy-name> -n sov-core-storage
```

## Best Practices

1. **Always specify `provider` explicitly** — omitting it silently defaults to `ceph`, which may create the wrong CR name for non-Ceph providers
2. **Use consistent resource names** — the StorageClass name on the managed cluster is `{resource-name}-{ofAccount}`; choose names that are unique and descriptive (e.g., `ceph-rbd`, `portworx-block`)
3. **Registration is idempotent** — re-invoking `POST /storage-registrations` with the same `ofAccount` × `provider` is safe and performs an upsert
4. **Scope delivery to a specific cluster** — always pass `clusterSelector.matchLabels.name` to avoid delivering to unintended clusters
5. **Poll until `Ready`** — `phase: Ready` on the Hub does not guarantee the StorageClass is available on the managed cluster; wait for `propagationStatus: Propagated`
