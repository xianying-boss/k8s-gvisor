package v1alpha1

import (
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// RuntimeType is the language runtime for the sandbox execution.
// +kubebuilder:validation:Enum=python;nodejs
type RuntimeType string

const (
	RuntimePython RuntimeType = "python"
	RuntimeNodeJS RuntimeType = "nodejs"
)

// SandboxPhase represents the current lifecycle state of a SandboxJob.
// +kubebuilder:validation:Enum=Pending;Scheduling;Running;Succeeded;Failed;Timeout
type SandboxPhase string

const (
	SandboxPhasePending    SandboxPhase = "Pending"
	SandboxPhaseScheduling SandboxPhase = "Scheduling"
	SandboxPhaseRunning    SandboxPhase = "Running"
	SandboxPhaseSucceeded  SandboxPhase = "Succeeded"
	SandboxPhaseFailed     SandboxPhase = "Failed"
	SandboxPhaseTimeout    SandboxPhase = "Timeout"
)

// ResourceSpec constrains CPU and memory for the sandbox container.
type ResourceSpec struct {
	// CPU limit, e.g. "500m"
	// +optional
	CPU resource.Quantity `json:"cpu,omitempty"`
	// Memory limit, e.g. "256Mi"
	// +optional
	Memory resource.Quantity `json:"memory,omitempty"`
}

// CodeSource defines where the sandbox source code comes from.
// Exactly one of Inline or ConfigMapRef must be set.
type CodeSource struct {
	// Inline is a raw code string embedded directly in the spec.
	// Suitable for short scripts; use ConfigMapRef for larger code.
	// +optional
	Inline string `json:"inline,omitempty"`

	// ConfigMapRef references a ConfigMap key that holds the source code.
	// +optional
	ConfigMapRef *corev1.ConfigMapKeySelector `json:"configMapRef,omitempty"`
}

// SandboxJobSpec defines the desired state of a SandboxJob.
type SandboxJobSpec struct {
	// Runtime selects the language runtime.
	// +kubebuilder:validation:Required
	Runtime RuntimeType `json:"runtime"`

	// Code is the source to execute inside the sandbox.
	// +kubebuilder:validation:Required
	Code CodeSource `json:"code"`

	// Packages lists pip (python) or npm (nodejs) packages to install before execution.
	// The operator checks Redis for a pre-warmed cache before installing.
	// +optional
	Packages []string `json:"packages,omitempty"`

	// TimeoutSeconds is the maximum wall-clock time allowed for execution.
	// The sandbox pod is killed and the job transitions to Timeout if exceeded.
	// +kubebuilder:default=30
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=300
	TimeoutSeconds int `json:"timeoutSeconds,omitempty"`

	// Resources sets CPU/memory limits for the execution container.
	// +optional
	Resources ResourceSpec `json:"resources,omitempty"`

	// Env injects environment variables into the execution container.
	// +optional
	Env []corev1.EnvVar `json:"env,omitempty"`

	// AllowNetworkEgress enables outbound internet access from the sandbox.
	// Disabled by default; a NetworkPolicy is applied when false.
	// +kubebuilder:default=false
	AllowNetworkEgress bool `json:"allowNetworkEgress,omitempty"`
}

// SandboxJobStatus reflects the observed state of a SandboxJob.
type SandboxJobStatus struct {
	// Phase is the current lifecycle phase of the job.
	Phase SandboxPhase `json:"phase,omitempty"`

	// PodName is the name of the gVisor execution pod created by the operator.
	// +optional
	PodName string `json:"podName,omitempty"`

	// Output captures up to 64KiB of stdout+stderr from the sandbox execution.
	// +optional
	Output string `json:"output,omitempty"`

	// ExitCode is the process exit code from the sandbox container.
	// +optional
	ExitCode int `json:"exitCode,omitempty"`

	// CacheHit is true when all requested packages were served from Redis cache,
	// bypassing the install step entirely.
	// +optional
	CacheHit bool `json:"cacheHit,omitempty"`

	// StartTime is when execution began inside the sandbox.
	// +optional
	StartTime *metav1.Time `json:"startTime,omitempty"`

	// CompletionTime is when the sandbox reached a terminal state.
	// +optional
	CompletionTime *metav1.Time `json:"completionTime,omitempty"`

	// Conditions provide structured status conditions following the Kubernetes API convention.
	// +optional
	// +patchMergeKey=type
	// +patchStrategy=merge
	Conditions []metav1.Condition `json:"conditions,omitempty" patchStrategy:"merge" patchMergeKey:"type"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Namespaced,shortName=sbj,categories=sandbox
// +kubebuilder:printcolumn:name="Runtime",type=string,JSONPath=`.spec.runtime`
// +kubebuilder:printcolumn:name="Phase",type=string,JSONPath=`.status.phase`
// +kubebuilder:printcolumn:name="CacheHit",type=boolean,JSONPath=`.status.cacheHit`
// +kubebuilder:printcolumn:name="ExitCode",type=integer,JSONPath=`.status.exitCode`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`

// SandboxJob represents a single isolated code execution request.
// The operator schedules it onto gVisor-enabled execution-plane nodes.
type SandboxJob struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   SandboxJobSpec   `json:"spec,omitempty"`
	Status SandboxJobStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// SandboxJobList contains a list of SandboxJob resources.
type SandboxJobList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []SandboxJob `json:"items"`
}

func init() {
	SchemeBuilder.Register(&SandboxJob{}, &SandboxJobList{})
}
