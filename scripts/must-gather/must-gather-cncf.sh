#!/usr/bin/env bash
set -uo pipefail
IFS=$'\n\t'

# =============================================================================
# IBM Sovereign Core Must-Gather — CNCF Kubernetes
# =============================================================================

IMAGE="${MUST_GATHER_IMAGE:-}"
NAMESPACE="kube-system"
SERVICE_ACCOUNT="sovcore-must-gather"

OUTPUT_DIR="./must-gather-results"
PVC_SIZE="6Gi"
STORAGE_CLASS=""

NAMESPACES=""
PROFILE=""
MODES=""
KUBECONFIG_PATH=""

JOB_TIMEOUT=3600
POD_START_TIMEOUT=300
COPY_POD_TIMEOUT=180

CLEANUP_ON_FAILURE=false

RUN_ID="$(date -u '+%Y%m%d%H%M%S')-$$"

JOB_NAME="sovcore-mg-${RUN_ID}"
PVC_NAME="sovcore-mg-output-${RUN_ID}"
COPY_POD_NAME="sovcore-mg-copy-${RUN_ID}"

POD=""
JOB_NODE=""
FINAL_SUCCESS=0
JOB_MANIFEST=""

# =============================================================================
# HELPERS
# =============================================================================

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

warn() {
    echo "[WARN] $*" >&2
}

die() {
    echo "[ERROR] $*" >&2
    exit 1
}

usage() {
    cat <<EOF

Usage:
  $0 [options]

Options:
  -n, --namespaces <list>       Namespaces to collect
  -p, --profile <profile>       Must-Gather profile
  -m, --modes <modes>           Collection modes
  -i, --image <image>           Must-Gather image (required unless MUST_GATHER_IMAGE is set)
  -o, --output <directory>      Local output directory
  -k, --kubeconfig <file>       Kubeconfig file
  -s, --storage-class <name>    StorageClass override
                                If omitted, cluster default is used
      --pvc-size <size>          PVC size (default: 6Gi)
      --cleanup-on-failure       Cleanup resources even if collection fails
  -h, --help                    Show help

Examples:

  $0 -i <MUSTGATHER_IMAGE> -n vault -o .

  $0 -i <MUSTGATHER_IMAGE> -n vault,vault-unsealer -o . -s local-path

  $0 -i <MUSTGATHER_IMAGE> -p sovcore -o ./results

Environment alternative:

  export MUST_GATHER_IMAGE=<MUSTGATHER_IMAGE>
  $0 -n vault -o .

EOF
    exit 0
}

require_value() {
    [ -n "${2-}" ] || die "$1 requires a value."
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

while [[ $# -gt 0 ]]; do
    case "$1" in

        -n|--namespaces)
            require_value "$1" "${2-}"
            NAMESPACES="$2"
            shift 2
            ;;

        -p|--profile)
            require_value "$1" "${2-}"
            PROFILE="$2"
            shift 2
            ;;

        -m|--modes)
            require_value "$1" "${2-}"
            MODES="$2"
            shift 2
            ;;

        -i|--image)
            require_value "$1" "${2-}"
            IMAGE="$2"
            shift 2
            ;;

        -o|--output)
            require_value "$1" "${2-}"
            OUTPUT_DIR="$2"
            shift 2
            ;;

        -k|--kubeconfig)
            require_value "$1" "${2-}"
            KUBECONFIG_PATH="$2"
            shift 2
            ;;

        -s|--storage-class)
            require_value "$1" "${2-}"
            STORAGE_CLASS="$2"
            shift 2
            ;;

        --pvc-size)
            require_value "$1" "${2-}"
            PVC_SIZE="$2"
            shift 2
            ;;

        --cleanup-on-failure)
            CLEANUP_ON_FAILURE=true
            shift
            ;;

        -h|--help)
            usage
            ;;

        *)
            die "Unknown option: $1"
            ;;
    esac
done

[ -n "$IMAGE" ] || \
    die "Must-Gather image is required. Use -i/--image <image> or set MUST_GATHER_IMAGE."

# =============================================================================
# KUBECTL
# =============================================================================

command -v kubectl >/dev/null 2>&1 || \
    die "kubectl is not available."

KUBECTL=(kubectl)

if [ -n "$KUBECONFIG_PATH" ]; then
    [ -f "$KUBECONFIG_PATH" ] || \
        die "Kubeconfig not found: $KUBECONFIG_PATH"

    KUBECTL+=(--kubeconfig "$KUBECONFIG_PATH")
fi

k() {
    "${KUBECTL[@]}" "$@"
}

# =============================================================================
# CLEANUP
# =============================================================================

cleanup_resources() {

    log "Cleaning up Kubernetes resources..."

    k delete pod "$COPY_POD_NAME" \
        -n "$NAMESPACE" \
        --ignore-not-found=true \
        --wait=true \
        --timeout=60s >/dev/null 2>&1 || true

    k delete job "$JOB_NAME" \
        -n "$NAMESPACE" \
        --ignore-not-found=true \
        --wait=true \
        --timeout=60s >/dev/null 2>&1 || true

    k delete pvc "$PVC_NAME" \
        -n "$NAMESPACE" \
        --ignore-not-found=true \
        --wait=false >/dev/null 2>&1 || true

    log "Cleanup complete."
}

on_exit() {

    rc=$?

    [ -n "$JOB_MANIFEST" ] && rm -f "$JOB_MANIFEST"

    if [ "$FINAL_SUCCESS" -eq 1 ]; then

        cleanup_resources

    elif [ "$CLEANUP_ON_FAILURE" = true ]; then

        warn "Run failed. Cleaning resources."
        cleanup_resources

    else

        warn "Run did not complete successfully."
        warn "Resources are preserved for investigation:"
        warn "  Job : $JOB_NAME"
        warn "  PVC : $PVC_NAME"
        warn "  Pod : $COPY_POD_NAME"
    fi

    trap - EXIT
    exit "$rc"
}

# =============================================================================
# PRE-FLIGHT
# =============================================================================

log "============================================================"
log "IBM Sovereign Core Must-Gather — CNCF Kubernetes"
log "============================================================"

log "Checking cluster connectivity..."

k cluster-info >/dev/null 2>&1 || \
    die "Cannot connect to Kubernetes cluster."

log "Cluster connectivity verified."

k get namespace "$NAMESPACE" >/dev/null 2>&1 || \
    die "Namespace '$NAMESPACE' does not exist."

# =============================================================================
# RBAC BOOTSTRAP
# =============================================================================
# The script is self-contained for CNCF Kubernetes.
# kubectl apply is idempotent, so the SA/ClusterRole/Binding can be applied
# on every invocation. The caller must have permission to manage these RBAC
# resources.

log "Ensuring Must-Gather ServiceAccount and read-only RBAC..."

k apply -f - >/dev/null <<'RBAC_EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: sovcore-must-gather
  namespace: kube-system
  labels:
    app: sovcore-must-gather
    platform: cncf
    version: v2.0.0
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: sovcore-must-gather-cncf
  labels:
    app: sovcore-must-gather
    platform: cncf
    version: v2.0.0
rules:
- apiGroups: [""]
  resources:
  - pods
  - pods/log
  - pods/status
  - nodes
  - namespaces
  - services
  - endpoints
  - persistentvolumes
  - persistentvolumeclaims
  - configmaps
  - resourcequotas
  - limitranges
  - serviceaccounts
  - events
  - replicationcontrollers
  verbs: ["get", "list"]
- apiGroups: ["apps"]
  resources: ["deployments", "statefulsets", "daemonsets", "replicasets"]
  verbs: ["get", "list"]
- apiGroups: ["batch"]
  resources: ["jobs", "cronjobs"]
  verbs: ["get", "list"]
- apiGroups: ["networking.k8s.io"]
  resources: ["ingresses", "networkpolicies", "ingressclasses"]
  verbs: ["get", "list"]
- apiGroups: ["discovery.k8s.io"]
  resources: ["endpointslices"]
  verbs: ["get", "list"]
- apiGroups: ["storage.k8s.io"]
  resources: ["storageclasses", "csidrivers", "csinodes", "csistoragecapacities"]
  verbs: ["get", "list"]
- apiGroups: ["snapshot.storage.k8s.io"]
  resources: ["volumesnapshots", "volumesnapshotclasses", "volumesnapshotcontents"]
  verbs: ["get", "list"]
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["clusterroles", "clusterrolebindings", "roles", "rolebindings"]
  verbs: ["get", "list"]
- apiGroups: ["apiextensions.k8s.io"]
  resources: ["customresourcedefinitions"]
  verbs: ["get", "list"]
- apiGroups: ["apiregistration.k8s.io"]
  resources: ["apiservices"]
  verbs: ["get", "list"]
- apiGroups: ["scheduling.k8s.io"]
  resources: ["priorityclasses"]
  verbs: ["get", "list"]
- apiGroups: ["node.k8s.io"]
  resources: ["runtimeclasses"]
  verbs: ["get", "list"]
- apiGroups: ["admissionregistration.k8s.io"]
  resources: ["mutatingwebhookconfigurations", "validatingwebhookconfigurations"]
  verbs: ["get", "list"]
- apiGroups: ["policy"]
  resources: ["poddisruptionbudgets"]
  verbs: ["get", "list"]
- apiGroups: ["argoproj.io"]
  resources: ["applications", "applicationsets", "appprojects", "argocds"]
  verbs: ["get", "list"]
- apiGroups: ["tekton.dev"]
  resources: ["pipelines", "pipelineruns", "tasks", "taskruns", "clustertasks"]
  verbs: ["get", "list"]
- apiGroups: ["triggers.tekton.dev"]
  resources: ["triggertemplates", "triggerbindings", "eventlisteners"]
  verbs: ["get", "list"]
- apiGroups: ["sovcore.ibm.com"]
  resources: ["*"]
  verbs: ["get", "list"]
- apiGroups: ["operator.ibm.com"]
  resources: ["ibmlicensings", "operandrequests", "operandregistries"]
  verbs: ["get", "list"]
- apiGroups: ["cert-manager.io"]
  resources: ["certificates", "certificaterequests", "challenges", "clusterissuers", "issuers", "orders"]
  verbs: ["get", "list"]
- apiGroups: ["operators.coreos.com"]
  resources: ["clusterserviceversions", "subscriptions", "installplans", "catalogsources", "operatorgroups"]
  verbs: ["get", "list"]
- nonResourceURLs: ["/healthz", "/readyz", "/version", "/metrics"]
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: sovcore-must-gather-cncf
  labels:
    app: sovcore-must-gather
    platform: cncf
    version: v2.0.0
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: sovcore-must-gather-cncf
subjects:
- kind: ServiceAccount
  name: sovcore-must-gather
  namespace: kube-system
RBAC_EOF

k get serviceaccount "$SERVICE_ACCOUNT" \
    -n "$NAMESPACE" >/dev/null 2>&1 || \
    die "Failed to create or find ServiceAccount '$SERVICE_ACCOUNT' in '$NAMESPACE'."

log "Must-Gather RBAC is ready."

# =============================================================================
# STORAGE CLASS
# =============================================================================

if [ -z "$STORAGE_CLASS" ]; then

    log "StorageClass not specified. Detecting cluster default..."

    STORAGE_CLASS="$(
        k get storageclass \
          -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' \
          2>/dev/null |
        head -1
    )"

    # Support older default StorageClass annotation also
    if [ -z "$STORAGE_CLASS" ]; then

        STORAGE_CLASS="$(
            k get storageclass \
              -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.beta\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' \
              2>/dev/null |
            head -1
        )"
    fi

    if [ -z "$STORAGE_CLASS" ]; then
        echo ""
        k get storageclass || true
        echo ""

        die "No default StorageClass found. Use --storage-class <name>."
    fi

    log "Using default StorageClass: $STORAGE_CLASS"

else

    k get storageclass "$STORAGE_CLASS" >/dev/null 2>&1 || \
        die "StorageClass '$STORAGE_CLASS' does not exist."

    log "Using StorageClass: $STORAGE_CLASS"
fi

log "Image:        $IMAGE"
log "Namespace:    $NAMESPACE"
log "StorageClass: $STORAGE_CLASS"
log "PVC size:     $PVC_SIZE"
log "Namespaces:   ${NAMESPACES:-all}"
log "Profile:      ${PROFILE:-all}"
log "Modes:        ${MODES:-all}"
log "Output:       $OUTPUT_DIR"

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# =============================================================================
# STEP 1 — CREATE PVC
# =============================================================================

echo ""
log "Step 1/5 — Creating PVC..."

k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $PVC_NAME
  namespace: $NAMESPACE
  labels:
    app: sovcore-must-gather
    run-id: "$RUN_ID"
spec:
  storageClassName: "$STORAGE_CLASS"
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: "$PVC_SIZE"
EOF

log "PVC created: $PVC_NAME"

#
# IMPORTANT:
# Do not wait for PVC Bound here.
#
# StorageClasses using WaitForFirstConsumer remain Pending
# until the consuming Job pod is scheduled.
#

# =============================================================================
# STEP 2 — RUN MUST-GATHER
# =============================================================================

echo ""
log "Step 2/5 — Starting Must-Gather Job..."

JOB_MANIFEST="$(mktemp)"

cat > "$JOB_MANIFEST" <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB_NAME
  namespace: $NAMESPACE
  labels:
    app: sovcore-must-gather
    run-id: "$RUN_ID"
spec:
  backoffLimit: 0
  template:
    metadata:
      labels:
        app: sovcore-must-gather
        run-id: "$RUN_ID"
    spec:
      serviceAccountName: $SERVICE_ACCOUNT
      restartPolicy: Never

      volumes:
        - name: output
          persistentVolumeClaim:
            claimName: $PVC_NAME

      containers:
        - name: must-gather
          image: "$IMAGE"
          imagePullPolicy: Always

          command:
            - /usr/bin/gather_cncf

          args:
            - "--output"
            - "/output"
EOF

if [ -n "$NAMESPACES" ]; then
cat >> "$JOB_MANIFEST" <<EOF
            - "--namespaces"
            - "$NAMESPACES"
EOF
fi

if [ -n "$PROFILE" ]; then
cat >> "$JOB_MANIFEST" <<EOF
            - "--profile"
            - "$PROFILE"
EOF
fi

if [ -n "$MODES" ]; then
cat >> "$JOB_MANIFEST" <<EOF
            - "--modes"
            - "$MODES"
EOF
fi

cat >> "$JOB_MANIFEST" <<EOF

          volumeMounts:
            - name: output
              mountPath: /output
EOF

k apply -f "$JOB_MANIFEST" >/dev/null

log "Job created: $JOB_NAME"
log "Waiting for pod..."

POD=""

DEADLINE=$(( $(date +%s) + POD_START_TIMEOUT ))

while [ "$(date +%s)" -lt "$DEADLINE" ]; do

    POD="$(
        k get pod \
          -n "$NAMESPACE" \
          -l "job-name=$JOB_NAME" \
          -o jsonpath='{.items[0].metadata.name}' \
          2>/dev/null || true
    )"

    [ -n "$POD" ] && break

    sleep 2
done

if [ -z "$POD" ]; then
    k describe job "$JOB_NAME" -n "$NAMESPACE" || true
    die "Must-Gather pod was not created."
fi

log "Pod: $POD"

# =============================================================================
# WAIT FOR CONTAINER START
# =============================================================================

log "Waiting for collection container..."

DEADLINE=$(( $(date +%s) + POD_START_TIMEOUT ))

POD_PHASE=""

while [ "$(date +%s)" -lt "$DEADLINE" ]; do

    POD_PHASE="$(
        k get pod "$POD" \
          -n "$NAMESPACE" \
          -o jsonpath='{.status.phase}' \
          2>/dev/null || true
    )"

    WAIT_REASON="$(
        k get pod "$POD" \
          -n "$NAMESPACE" \
          -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' \
          2>/dev/null || true
    )"

    case "$WAIT_REASON" in
        ErrImagePull|ImagePullBackOff|InvalidImageName|CreateContainerConfigError|CreateContainerError)

            warn "Container failed to start: $WAIT_REASON"

            k describe pod "$POD" \
                -n "$NAMESPACE" || true

            die "Must-Gather container startup failed."
            ;;
    esac

    case "$POD_PHASE" in
        Running|Succeeded|Failed)
            break
            ;;
    esac

    sleep 2
done

case "$POD_PHASE" in
    Running|Succeeded|Failed)
        ;;
    *)
        k describe pod "$POD" -n "$NAMESPACE" || true
        echo ""
        k describe pvc "$PVC_NAME" -n "$NAMESPACE" || true

        die "Must-Gather pod startup timed out."
        ;;
esac

# =============================================================================
# STREAM LOGS
# =============================================================================

echo ""
log "Streaming Must-Gather logs..."
echo "------------------------------------------------------------"

k logs \
  -n "$NAMESPACE" \
  "$POD" \
  -c must-gather \
  -f || true

echo "------------------------------------------------------------"

# =============================================================================
# WAIT FOR COMPLETION
# =============================================================================

log "Waiting for collection to complete..."

DEADLINE=$(( $(date +%s) + JOB_TIMEOUT ))

while [ "$(date +%s)" -lt "$DEADLINE" ]; do

    POD_PHASE="$(
        k get pod "$POD" \
          -n "$NAMESPACE" \
          -o jsonpath='{.status.phase}' \
          2>/dev/null || true
    )"

    case "$POD_PHASE" in
        Succeeded|Failed)
            break
            ;;
    esac

    sleep 2
done

if [ "$POD_PHASE" != "Succeeded" ] && \
   [ "$POD_PHASE" != "Failed" ]; then

    k describe pod "$POD" -n "$NAMESPACE" || true

    die "Must-Gather timed out after ${JOB_TIMEOUT}s."
fi

EXIT_CODE="$(
    k get pod "$POD" \
      -n "$NAMESPACE" \
      -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' \
      2>/dev/null || true
)"

EXIT_CODE="${EXIT_CODE:-unknown}"

log "Pod status: $POD_PHASE"
log "Container exit code: $EXIT_CODE"

if [ "$EXIT_CODE" != "0" ]; then
    warn "Collection returned exit code $EXIT_CODE."
    warn "Trying to retrieve generated archive."
fi

# Find node used by Job
JOB_NODE="$(
    k get pod "$POD" \
      -n "$NAMESPACE" \
      -o jsonpath='{.spec.nodeName}' \
      2>/dev/null || true
)"

[ -n "$JOB_NODE" ] || \
    die "Unable to determine Must-Gather node."

log "Must-Gather node: $JOB_NODE"

# =============================================================================
# STEP 3 — COPY POD
# =============================================================================

echo ""
log "Step 3/5 — Creating copy pod..."

#
# Same node is used intentionally.
# Helpful for RWO/local volume StorageClasses.
#

k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $COPY_POD_NAME
  namespace: $NAMESPACE
  labels:
    app: sovcore-must-gather
    run-id: "$RUN_ID"
spec:
  nodeName: "$JOB_NODE"
  restartPolicy: Never

  volumes:
    - name: output
      persistentVolumeClaim:
        claimName: $PVC_NAME

  containers:
    - name: copy
      image: "$IMAGE"
      imagePullPolicy: IfNotPresent

      command:
        - /bin/sh
        - -c
        - "sleep 3600"

      volumeMounts:
        - name: output
          mountPath: /output
EOF

log "Waiting for copy pod..."

if ! k wait pod "$COPY_POD_NAME" \
    -n "$NAMESPACE" \
    --for=condition=Ready \
    --timeout="${COPY_POD_TIMEOUT}s" >/dev/null 2>&1; then

    k describe pod "$COPY_POD_NAME" \
        -n "$NAMESPACE" || true

    die "Copy pod failed to become Ready."
fi

log "Copy pod ready."

# =============================================================================
# STEP 4 — COPY ARCHIVE TO LOCAL
# =============================================================================

echo ""
log "Step 4/5 — Locating archive..."

REMOTE_ARCHIVE="$(
    k exec \
      -n "$NAMESPACE" \
      "$COPY_POD_NAME" \
      -c copy \
      -- /bin/sh -c '
          for f in /output/sovcore-must-gather-*.tar.gz; do
              [ -f "$f" ] && echo "$f"
          done
      ' 2>/dev/null |
    tail -1
)"

if [ -z "$REMOTE_ARCHIVE" ]; then

    warn "No tar.gz archive found."

    k exec \
      -n "$NAMESPACE" \
      "$COPY_POD_NAME" \
      -c copy \
      -- ls -lah /output || true

    die "Must-Gather archive was not generated."
fi

ARCHIVE_NAME="$(basename "$REMOTE_ARCHIVE")"

mkdir -p "$OUTPUT_DIR"

LOCAL_ARCHIVE="$OUTPUT_DIR/$ARCHIVE_NAME"

log "Archive found: $ARCHIVE_NAME"
log "Copying archive to: $LOCAL_ARCHIVE"

#
# Using cat instead of kubectl cp.
# This avoids dependency on tar inside the container.
#

if ! k exec \
    -n "$NAMESPACE" \
    "$COPY_POD_NAME" \
    -c copy \
    -- cat "$REMOTE_ARCHIVE" > "$LOCAL_ARCHIVE"; then

    rm -f "$LOCAL_ARCHIVE"

    die "Failed to copy archive."
fi

[ -s "$LOCAL_ARCHIVE" ] || \
    die "Copied archive is empty."

log "Validating archive..."

tar -tzf "$LOCAL_ARCHIVE" >/dev/null 2>&1 || \
    die "Archive validation failed."

log "Archive copied and validated successfully."

# =============================================================================
# OPTIONAL EXTRACTION
# =============================================================================

EXTRACT_DIR="$OUTPUT_DIR/sovcore-must-gather-${RUN_ID}"

mkdir -p "$EXTRACT_DIR"

log "Extracting archive..."

tar -xzf "$LOCAL_ARCHIVE" \
    -C "$EXTRACT_DIR"

log "Extracted to: $EXTRACT_DIR"

ERROR_LOG="$(
    find "$EXTRACT_DIR" \
      -type f \
      -name collection-errors.log \
      -print \
      -quit 2>/dev/null || true
)"

if [ -n "$ERROR_LOG" ]; then
    log "Collection errors log: $ERROR_LOG"
fi

# =============================================================================
# STEP 5 — FINALIZE
# =============================================================================

echo ""
log "Step 5/5 — Finalizing..."

if [ "$EXIT_CODE" != "0" ]; then

    warn "Archive retrieved successfully,"
    warn "but Must-Gather exited with code $EXIT_CODE."

    exit 2
fi

FINAL_SUCCESS=1

echo ""
log "============================================================"
log "Must-Gather completed successfully"
log "============================================================"
log "Archive  : $LOCAL_ARCHIVE"
log "Extracted: $EXTRACT_DIR"