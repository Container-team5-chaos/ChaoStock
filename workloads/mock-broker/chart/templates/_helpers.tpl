{{- define "mock-broker.labels" -}}
app: mock-broker
app.kubernetes.io/name: mock-broker
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
{{- define "mock-broker.env" -}}
- name: PGHOST
  value: {{ .Values.database.host | quote }}
- name: PGPORT
  value: {{ .Values.database.port | quote }}
- name: REDIS_URL
  value: {{ .Values.config.redisUrl | quote }}
- name: STALE_MS
  value: {{ .Values.config.staleMs | quote }}
- name: DB_POOL_SIZE
  value: {{ .Values.config.dbPoolSize | quote }}
- name: RESPONSE_DELAY_SECONDS
  value: {{ .Values.config.responseDelaySeconds | quote }}
- name: RATE_LIMIT_RPS
  value: {{ .Values.config.rateLimitRps | quote }}
{{- end }}
