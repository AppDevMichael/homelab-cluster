{{/* Common sync policy for every app */}}
{{- define "bootstrap.syncPolicy" -}}
syncPolicy:
  automated:
    prune: true
    selfHeal: true
  retry:
    limit: 5
    backoff:
      duration: 30s
      factor: 2
      maxDuration: 5m
  syncOptions:
    - CreateNamespace=true
    - ServerSideApply=true
    - RespectIgnoreDifferences=true
    - ApplyOutOfSyncOnly=true
{{- end -}}

{{/* Charts whose operator injects a CA into its own webhooks: not drift */}}
{{- define "bootstrap.ignoreWebhookCA" -}}
ignoreDifferences:
  - group: admissionregistration.k8s.io
    kind: MutatingWebhookConfiguration
    jqPathExpressions: [".webhooks[].clientConfig.caBundle"]
  - group: admissionregistration.k8s.io
    kind: ValidatingWebhookConfiguration
    jqPathExpressions: [".webhooks[].clientConfig.caBundle"]
{{- end -}}
