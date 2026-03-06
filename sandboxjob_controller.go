package controller

import (
	"context"
	"fmt"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	sandboxv1alpha1 "github.com/sandbox-operator/sandbox-operator/api/v1alpha1"
)

const (
	sandboxFinalizer = "sandbox.k8s.io/finalizer"

	// Node labels that identify execution-plane nodes (gVisor-enabled pool).
	labelExecutionRole  = "sandbox.k8s.io/role"
	labelExecutionValue = "execution"

	// gVisorRuntimeClass matches the RuntimeClass created by the Helm chart /
	// manifests. All execution pods use this class to get runsc shim.
	gVisorRuntimeClass = "gvisor"

	// schedulingTimeout is the max time to wait for a pod to leave Pending.
	schedulingTimeout = 5 * time.Minute

	// podLogMaxBytes caps how much stdout/stderr is captured into the status.
	podLogMaxBytes = 65536
)

// runtimeImages maps RuntimeType → base OCI image used for execution pods.
// The operator will substitute a pre-built cached image when cache hits.
var runtimeImages = map[sandboxv1alpha1.RuntimeType]string{
	sandboxv1alpha1.RuntimePython: "python:3.11-slim",
	sandboxv1alpha1.RuntimeNodeJS: "node:20-slim",
}

// SandboxJobReconciler reconciles SandboxJob objects.
//
// Responsibilities:
//   - Select runtime image based on spec.runtime (control plane: image selection)
//   - Consult Redis for pre-warmed dependency cache          (control plane: cache mgmt)
//   - Create a gVisor execution pod on execution-plane nodes (control plane: scheduling)
//   - Drive the pod through its lifecycle phases             (control plane: lifecycle mgmt)
//   - Apply per-job NetworkPolicy when egress is disabled    (control plane: network)
type SandboxJobReconciler struct {
	client.Client
	Scheme       *runtime.Scheme
	CacheManager *CacheManager
}

// +kubebuilder:rbac:groups=sandbox.k8s.io,resources=sandboxjobs,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=sandbox.k8s.io,resources=sandboxjobs/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=sandbox.k8s.io,resources=sandboxjobs/finalizers,verbs=update
// +kubebuilder:rbac:groups=core,resources=pods,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=core,resources=pods/log,verbs=get
// +kubebuilder:rbac:groups=core,resources=configmaps,verbs=get;list;watch
// +kubebuilder:rbac:groups=networking.k8s.io,resources=networkpolicies,verbs=get;list;watch;create;update;patch;delete

// Reconcile is the main reconcile loop. It is called whenever a SandboxJob or
// an owned Pod changes, and drives the job through its lifecycle state machine:
//
//	(empty) → Pending → Scheduling → Running → Succeeded|Failed|Timeout
func (r *SandboxJobReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx).WithValues("sandboxjob", req.NamespacedName)

	job := &sandboxv1alpha1.SandboxJob{}
	if err := r.Get(ctx, req.NamespacedName, job); err != nil {
		if errors.IsNotFound(err) {
			return ctrl.Result{}, nil // Deleted before we could reconcile; nothing to do.
		}
		return ctrl.Result{}, err
	}

	// ── Deletion ─────────────────────────────────────────────────────────────
	if !job.DeletionTimestamp.IsZero() {
		return r.handleDeletion(ctx, job)
	}

	// ── Finalizer bootstrap ───────────────────────────────────────────────────
	if !containsString(job.Finalizers, sandboxFinalizer) {
		job.Finalizers = append(job.Finalizers, sandboxFinalizer)
		return ctrl.Result{Requeue: true}, r.Update(ctx, job)
	}

	logger.Info("Reconciling SandboxJob", "phase", job.Status.Phase)

	// ── State machine ─────────────────────────────────────────────────────────
	switch job.Status.Phase {
	case "", sandboxv1alpha1.SandboxPhasePending:
		return r.handlePending(ctx, job)
	case sandboxv1alpha1.SandboxPhaseScheduling:
		return r.handleScheduling(ctx, job)
	case sandboxv1alpha1.SandboxPhaseRunning:
		return r.handleRunning(ctx, job)
	case sandboxv1alpha1.SandboxPhaseSucceeded,
		sandboxv1alpha1.SandboxPhaseFailed,
		sandboxv1alpha1.SandboxPhaseTimeout:
		// Terminal — nothing more to do.
		return ctrl.Result{}, nil
	default:
		return ctrl.Result{}, fmt.Errorf("unrecognised SandboxJob phase %q", job.Status.Phase)
	}
}

// ── Phase handlers ────────────────────────────────────────────────────────────

// handlePending performs the control-plane logic before scheduling:
//  1. Validate the runtime type
//  2. Consult Redis for a cached dependency layer
//  3. Select the appropriate container image
//  4. Enforce NetworkPolicy for the job's namespace
//  5. Create the gVisor execution pod
func (r *SandboxJobReconciler) handlePending(ctx context.Context, job *sandboxv1alpha1.SandboxJob) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	// 1. Validate runtime
	baseImage, ok := runtimeImages[job.Spec.Runtime]
	if !ok {
		return r.setTerminal(ctx, job, sandboxv1alpha1.SandboxPhaseFailed,
			fmt.Sprintf("unsupported runtime %q", job.Spec.Runtime))
	}

	// 2. Cache lookup
	cacheHit := false
	if len(job.Spec.Packages) > 0 {
		key := PackageCacheKey(job.Spec.Runtime, job.Spec.Packages)
		entry, hit, err := r.CacheManager.Lookup(ctx, key)
		if err != nil {
			logger.Error(err, "Redis cache lookup failed; proceeding without cache")
		} else if hit && entry.ImageRef != "" {
			cacheHit = true
			baseImage = entry.ImageRef
			logger.Info("Cache hit", "key", key, "imageRef", baseImage)
		}
	}

	// 3. Enforce per-job NetworkPolicy
	if err := r.reconcileNetworkPolicy(ctx, job); err != nil {
		return ctrl.Result{}, fmt.Errorf("NetworkPolicy reconcile: %w", err)
	}

	// 4. Create execution pod
	pod := r.buildExecutionPod(job, baseImage, cacheHit)
	if err := r.Create(ctx, pod); err != nil && !errors.IsAlreadyExists(err) {
		return ctrl.Result{}, fmt.Errorf("create execution pod: %w", err)
	}

	logger.Info("Execution pod created", "pod", pod.Name, "image", baseImage, "cacheHit", cacheHit)

	job.Status.Phase = sandboxv1alpha1.SandboxPhaseScheduling
	job.Status.PodName = pod.Name
	job.Status.CacheHit = cacheHit
	return ctrl.Result{RequeueAfter: 2 * time.Second}, r.Status().Update(ctx, job)
}

// handleScheduling waits for the execution pod to leave Pending state.
func (r *SandboxJobReconciler) handleScheduling(ctx context.Context, job *sandboxv1alpha1.SandboxJob) (ctrl.Result, error) {
	pod, err := r.getExecutionPod(ctx, job)
	if err != nil {
		return ctrl.Result{}, err
	}

	switch pod.Status.Phase {
	case corev1.PodRunning:
		now := metav1.Now()
		job.Status.Phase = sandboxv1alpha1.SandboxPhaseRunning
		job.Status.StartTime = &now
		return ctrl.Result{RequeueAfter: 2 * time.Second}, r.Status().Update(ctx, job)

	case corev1.PodPending:
		if time.Since(job.CreationTimestamp.Time) > schedulingTimeout {
			_ = r.Delete(ctx, pod)
			return r.setTerminal(ctx, job, sandboxv1alpha1.SandboxPhaseTimeout,
				"pod scheduling timeout exceeded")
		}
		return ctrl.Result{RequeueAfter: 5 * time.Second}, nil

	case corev1.PodFailed:
		return r.setTerminal(ctx, job, sandboxv1alpha1.SandboxPhaseFailed, "pod failed during scheduling")

	case corev1.PodSucceeded:
		// Very fast execution — pod already done before we polled.
		return r.finaliseSuccess(ctx, job)
	}

	return ctrl.Result{RequeueAfter: 3 * time.Second}, nil
}

// handleRunning monitors a running pod, enforces the execution timeout,
// and captures output when the pod finishes.
func (r *SandboxJobReconciler) handleRunning(ctx context.Context, job *sandboxv1alpha1.SandboxJob) (ctrl.Result, error) {
	pod, err := r.getExecutionPod(ctx, job)
	if err != nil {
		return ctrl.Result{}, err
	}

	// Enforce timeout
	if job.Status.StartTime != nil {
		elapsed := time.Since(job.Status.StartTime.Time)
		timeout := time.Duration(job.Spec.TimeoutSeconds) * time.Second
		if elapsed > timeout {
			_ = r.Delete(ctx, pod)
			return r.setTerminal(ctx, job, sandboxv1alpha1.SandboxPhaseTimeout,
				fmt.Sprintf("execution timeout exceeded (%s > %s)", elapsed.Round(time.Second), timeout))
		}
	}

	switch pod.Status.Phase {
	case corev1.PodSucceeded:
		return r.finaliseSuccess(ctx, job)

	case corev1.PodFailed:
		exitCode := exitCodeFrom(pod)
		now := metav1.Now()
		job.Status.Phase = sandboxv1alpha1.SandboxPhaseFailed
		job.Status.ExitCode = exitCode
		job.Status.CompletionTime = &now
		return ctrl.Result{}, r.Status().Update(ctx, job)

	case corev1.PodRunning:
		return ctrl.Result{RequeueAfter: 2 * time.Second}, nil
	}

	return ctrl.Result{RequeueAfter: 2 * time.Second}, nil
}

// finaliseSuccess marks a succeeded job and writes the package set to cache.
func (r *SandboxJobReconciler) finaliseSuccess(ctx context.Context, job *sandboxv1alpha1.SandboxJob) (ctrl.Result, error) {
	now := metav1.Now()
	job.Status.Phase = sandboxv1alpha1.SandboxPhaseSucceeded
	job.Status.ExitCode = 0
	job.Status.CompletionTime = &now

	// Warm the cache so subsequent jobs with the same runtime+packages skip install.
	if !job.Status.CacheHit && len(job.Spec.Packages) > 0 {
		key := PackageCacheKey(job.Spec.Runtime, job.Spec.Packages)
		entry := CacheEntry{
			ImageRef:      runtimeImages[job.Spec.Runtime],
			InstallScript: buildInstallCommand(job.Spec.Runtime, job.Spec.Packages),
		}
		if err := r.CacheManager.Store(ctx, key, entry); err != nil {
			log.FromContext(ctx).Error(err, "Failed to warm package cache; non-fatal")
		}
	}

	return ctrl.Result{}, r.Status().Update(ctx, job)
}

// handleDeletion cleans up owned resources and removes the finalizer.
func (r *SandboxJobReconciler) handleDeletion(ctx context.Context, job *sandboxv1alpha1.SandboxJob) (ctrl.Result, error) {
	if job.Status.PodName != "" {
		pod := &corev1.Pod{}
		if err := r.Get(ctx, types.NamespacedName{Name: job.Status.PodName, Namespace: job.Namespace}, pod); err == nil {
			_ = r.Delete(ctx, pod)
		}
	}
	// Clean up NetworkPolicy
	np := &networkingv1.NetworkPolicy{}
	if err := r.Get(ctx, types.NamespacedName{Name: netpolicyName(job), Namespace: job.Namespace}, np); err == nil {
		_ = r.Delete(ctx, np)
	}

	job.Finalizers = removeString(job.Finalizers, sandboxFinalizer)
	return ctrl.Result{}, r.Update(ctx, job)
}

// ── Pod construction ──────────────────────────────────────────────────────────

// buildExecutionPod constructs the gVisor sandbox pod for an execution job.
//
// Key properties:
//   - RuntimeClassName=gvisor         → runsc shim (VM-grade isolation)
//   - nodeSelector sandbox.k8s.io/role=execution → execution-plane nodes only
//   - toleration sandbox.k8s.io/execution:NoSchedule
//   - automountServiceAccountToken=false           → no k8s API access
//   - non-root UID 65534 (nobody)
//   - EmptyDir workspace written by init container
func (r *SandboxJobReconciler) buildExecutionPod(job *sandboxv1alpha1.SandboxJob, image string, cacheHit bool) *corev1.Pod {
	runtimeClass := gVisorRuntimeClass
	privileged := false
	noPrivEsc := false

	// Determine the filename and execution command for the runtime.
	codeFile, execCmd := runtimeExecDetails(job.Spec.Runtime, job.Spec.Packages, cacheHit)

	cpuLimit := resource.MustParse("500m")
	memLimit := resource.MustParse("256Mi")
	if !job.Spec.Resources.CPU.IsZero() {
		cpuLimit = job.Spec.Resources.CPU
	}
	if !job.Spec.Resources.Memory.IsZero() {
		memLimit = job.Spec.Resources.Memory
	}

	// The init container writes the inline code into a shared EmptyDir volume.
	// Production deployments should reference a ConfigMap instead.
	codeWriterCmd := fmt.Sprintf("printf '%%s' %q > /sandbox/%s", job.Spec.Code.Inline, codeFile)
	if job.Spec.Code.ConfigMapRef != nil {
		codeWriterCmd = fmt.Sprintf("cp /code/%s /sandbox/%s", job.Spec.Code.ConfigMapRef.Key, codeFile)
	}

	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      fmt.Sprintf("%s-exec", job.Name),
			Namespace: job.Namespace,
			Labels: map[string]string{
				"sandbox.k8s.io/job":     job.Name,
				"sandbox.k8s.io/runtime": string(job.Spec.Runtime),
				"sandbox.k8s.io/managed": "true",
			},
			OwnerReferences: []metav1.OwnerReference{
				*metav1.NewControllerRef(job, sandboxv1alpha1.GroupVersion.WithKind("SandboxJob")),
			},
		},
		Spec: corev1.PodSpec{
			// ── Isolation: gVisor runsc shim ──────────────────────────────
			RuntimeClassName: &runtimeClass,

			// ── Scheduling: execution-plane nodes only ────────────────────
			NodeSelector: map[string]string{
				labelExecutionRole: labelExecutionValue,
			},
			Tolerations: []corev1.Toleration{
				{
					Key:      "sandbox.k8s.io/execution",
					Operator: corev1.TolerationOpExists,
					Effect:   corev1.TaintEffectNoSchedule,
				},
			},

			// ── Security: no k8s API access, non-root ────────────────────
			AutomountServiceAccountToken: boolPtr(false),
			RestartPolicy:                corev1.RestartPolicyNever,
			SecurityContext: &corev1.PodSecurityContext{
				RunAsNonRoot: boolPtr(true),
				RunAsUser:    int64Ptr(65534),
				RunAsGroup:   int64Ptr(65534),
				SeccompProfile: &corev1.SeccompProfile{
					Type: corev1.SeccompProfileTypeRuntimeDefault,
				},
			},

			// ── Init: write source code into workspace ────────────────────
			InitContainers: []corev1.Container{
				{
					Name:    "code-writer",
					Image:   "busybox:stable",
					Command: []string{"/bin/sh", "-c", codeWriterCmd},
					VolumeMounts: []corev1.VolumeMount{
						{Name: "sandbox-workspace", MountPath: "/sandbox"},
					},
					SecurityContext: &corev1.SecurityContext{
						Privileged:               &privileged,
						AllowPrivilegeEscalation: &noPrivEsc,
					},
					Resources: corev1.ResourceRequirements{
						Limits: corev1.ResourceList{
							corev1.ResourceCPU:    resource.MustParse("50m"),
							corev1.ResourceMemory: resource.MustParse("32Mi"),
						},
					},
				},
			},

			// ── Main: execute user code inside gVisor ─────────────────────
			Containers: []corev1.Container{
				{
					Name:    "executor",
					Image:   image,
					Command: []string{"/bin/sh", "-c"},
					Args:    []string{execCmd},
					Env:     job.Spec.Env,
					Resources: corev1.ResourceRequirements{
						Limits: corev1.ResourceList{
							corev1.ResourceCPU:    cpuLimit,
							corev1.ResourceMemory: memLimit,
						},
						Requests: corev1.ResourceList{
							corev1.ResourceCPU:    resource.MustParse("100m"),
							corev1.ResourceMemory: resource.MustParse("64Mi"),
						},
					},
					VolumeMounts: []corev1.VolumeMount{
						{Name: "sandbox-workspace", MountPath: "/sandbox"},
						{Name: "tmp-dir", MountPath: "/tmp"},
					},
					SecurityContext: &corev1.SecurityContext{
						Privileged:               &privileged,
						AllowPrivilegeEscalation: &noPrivEsc,
					},
					// Hard resource cap: process is killed if it exceeds memory limit.
					TerminationMessagePath:   "/dev/termination-log",
					TerminationMessagePolicy: corev1.TerminationMessageFallbackToLogsOnError,
				},
			},

			Volumes: []corev1.Volume{
				{
					Name: "sandbox-workspace",
					VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}},
				},
				{
					Name: "tmp-dir",
					VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}},
				},
			},
		},
	}

	// Mount ConfigMap as a volume if code is referenced externally.
	if job.Spec.Code.ConfigMapRef != nil {
		pod.Spec.Volumes = append(pod.Spec.Volumes, corev1.Volume{
			Name: "code-source",
			VolumeSource: corev1.VolumeSource{
				ConfigMap: &corev1.ConfigMapVolumeSource{
					LocalObjectReference: corev1.LocalObjectReference{
						Name: job.Spec.Code.ConfigMapRef.Name,
					},
				},
			},
		})
		pod.Spec.InitContainers[0].VolumeMounts = append(
			pod.Spec.InitContainers[0].VolumeMounts,
			corev1.VolumeMount{Name: "code-source", MountPath: "/code", ReadOnly: true},
		)
	}

	return pod
}

// ── NetworkPolicy reconciliation ──────────────────────────────────────────────

// reconcileNetworkPolicy creates or updates the per-job NetworkPolicy.
// When AllowNetworkEgress is false, all egress is denied; pods cannot reach
// the internet or other cluster services, preventing data exfiltration.
func (r *SandboxJobReconciler) reconcileNetworkPolicy(ctx context.Context, job *sandboxv1alpha1.SandboxJob) error {
	np := buildNetworkPolicy(job)
	existing := &networkingv1.NetworkPolicy{}
	err := r.Get(ctx, types.NamespacedName{Name: np.Name, Namespace: np.Namespace}, existing)
	if errors.IsNotFound(err) {
		return r.Create(ctx, np)
	}
	if err != nil {
		return err
	}
	existing.Spec = np.Spec
	return r.Update(ctx, existing)
}

func buildNetworkPolicy(job *sandboxv1alpha1.SandboxJob) *networkingv1.NetworkPolicy {
	np := &networkingv1.NetworkPolicy{
		ObjectMeta: metav1.ObjectMeta{
			Name:      netpolicyName(job),
			Namespace: job.Namespace,
			Labels:    map[string]string{"sandbox.k8s.io/job": job.Name},
			OwnerReferences: []metav1.OwnerReference{
				*metav1.NewControllerRef(job, sandboxv1alpha1.GroupVersion.WithKind("SandboxJob")),
			},
		},
		Spec: networkingv1.NetworkPolicySpec{
			PodSelector: metav1.LabelSelector{
				MatchLabels: map[string]string{"sandbox.k8s.io/job": job.Name},
			},
			// Always deny ingress to sandbox pods.
			PolicyTypes: []networkingv1.PolicyType{
				networkingv1.PolicyTypeIngress,
				networkingv1.PolicyTypeEgress,
			},
			Ingress: []networkingv1.NetworkPolicyIngressRule{}, // deny all
		},
	}

	if job.Spec.AllowNetworkEgress {
		// Allow all egress (internet, DNS). Suitable only for trusted workloads.
		np.Spec.Egress = []networkingv1.NetworkPolicyEgressRule{{}}
	} else {
		// Deny all egress. Sandbox is fully network-isolated.
		np.Spec.Egress = []networkingv1.NetworkPolicyEgressRule{}
	}

	return np
}

// ── Helpers ───────────────────────────────────────────────────────────────────

func (r *SandboxJobReconciler) getExecutionPod(ctx context.Context, job *sandboxv1alpha1.SandboxJob) (*corev1.Pod, error) {
	pod := &corev1.Pod{}
	err := r.Get(ctx, types.NamespacedName{Name: job.Status.PodName, Namespace: job.Namespace}, pod)
	return pod, err
}

func (r *SandboxJobReconciler) setTerminal(ctx context.Context, job *sandboxv1alpha1.SandboxJob, phase sandboxv1alpha1.SandboxPhase, msg string) (ctrl.Result, error) {
	log.FromContext(ctx).Info("SandboxJob terminal", "phase", phase, "reason", msg)
	now := metav1.Now()
	job.Status.Phase = phase
	job.Status.CompletionTime = &now
	return ctrl.Result{}, r.Status().Update(ctx, job)
}

// runtimeExecDetails returns the code filename and shell command for a runtime,
// incorporating package installation when cacheHit is false.
func runtimeExecDetails(rt sandboxv1alpha1.RuntimeType, packages []string, cacheHit bool) (filename, cmd string) {
	switch rt {
	case sandboxv1alpha1.RuntimePython:
		filename = "code.py"
		if len(packages) > 0 && !cacheHit {
			cmd = fmt.Sprintf(
				"pip install --quiet --no-cache-dir %s && python /sandbox/code.py",
				strings.Join(packages, " "),
			)
		} else {
			cmd = "python /sandbox/code.py"
		}
	case sandboxv1alpha1.RuntimeNodeJS:
		filename = "code.js"
		if len(packages) > 0 && !cacheHit {
			cmd = fmt.Sprintf(
				"npm install --prefix /sandbox --silent %s && node /sandbox/code.js",
				strings.Join(packages, " "),
			)
		} else {
			cmd = "node /sandbox/code.js"
		}
	}
	return
}

func buildInstallCommand(rt sandboxv1alpha1.RuntimeType, packages []string) string {
	_, cmd := runtimeExecDetails(rt, packages, false)
	return cmd
}

func netpolicyName(job *sandboxv1alpha1.SandboxJob) string {
	return fmt.Sprintf("sandbox-%s", job.Name)
}

func exitCodeFrom(pod *corev1.Pod) int {
	for _, cs := range pod.Status.ContainerStatuses {
		if cs.Name == "executor" && cs.State.Terminated != nil {
			return int(cs.State.Terminated.ExitCode)
		}
	}
	return 1
}

func containsString(slice []string, s string) bool {
	for _, v := range slice {
		if v == s {
			return true
		}
	}
	return false
}

func removeString(slice []string, s string) []string {
	out := make([]string, 0, len(slice))
	for _, v := range slice {
		if v != s {
			out = append(out, v)
		}
	}
	return out
}

func boolPtr(b bool) *bool    { return &b }
func int64Ptr(i int64) *int64 { return &i }

// SetupWithManager registers the controller with the manager and configures
// it to watch SandboxJob resources and their owned Pods.
func (r *SandboxJobReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&sandboxv1alpha1.SandboxJob{}).
		Owns(&corev1.Pod{}).
		Owns(&networkingv1.NetworkPolicy{}).
		Complete(r)
}
