# OpenLDAP LDIF applier

## What is it?

OpenLDAP LDIF applier is something like ja 'Poor man's ldap operator'. It was build to automatically apply (templated) LDIF's to an openldap installation. I.e. automatically create users or groups and any other ldap structure.

Source code is located at: https://github.com/marvkis/openldap-ldif-applier

## TL;DR

I use it in (k3s) as a job. This is a sample configuration:

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: openldap-ldif
  labels:
    app: openldap
data:
  OU-serviceaccoutns.ldif: |-
    dn: ou=serviceaccoutns,{{ LDAP_BASE_DN }}
    objectClass: organizationalUnit
    ou: users

  USER-demo-services.ldif: |-
    dn: uid=demo-service,ou=serviceaccoutns,{{ LDAP_BASE_DN }}
    objectClass: account
    objectClass: simpleSecurityObject
    objectClass: top
    uid: demo-service
    userPassword: {{ LDAP_CUSTOM_DEMO_PASSWORD }}

---
apiVersion: v1
kind: Secret
metadata:
  name: openldap-secrets
type: bootstrap.kubernetes.io/token
stringData:
  LDAP_ADMIN_PASSWORD: "very-secret-ldap-admin-password"
  LDAP_CUSTOM_DEMO_PASSWORD: "lovely-ldap-demo-user-password"

---
apiVersion: batch/v1
kind: Job
metadata:
  name: openldap-ldif-applier
  namespace: identity
  labels:
    app: openldap
spec:
  ttlSecondsAfterFinished: 100
  template:
    spec:
      containers:
      - name: openldap-ldif-applier
        image: openldap-ldif-applier:latest
        env:
          - name: LDAP_URI
            value: "ldap://openldap:389/"
          - name: LDAP_DOMAIN
            value: "staging.lan"
          - name: LDAP_ADMIN_PASSWORD
            valueFrom:
              secretKeyRef:
                name: openldap-secrets
                key: LDAP_ADMIN_PASSWORD
          - name: LDAP_CUSTOM_DEMO_PASSWORD
            valueFrom:
              secretKeyRef:
                name: openldap-secrets
                key: LDAP_CUSTOM_DEMO_PASSWORD
        volumeMounts:
          - mountPath: /tmp
            name: container-tmp
          - name: openldap-ldif
            mountPath: /app/ldif
      restartPolicy: Never
      volumes:
        - name: container-tmp
          emptyDir: {}
        - name: openldap-ldif
          configMap:
            name: openldap-ldif

```

## How does it work?

this *operator* expects a single LDIF entry in every file located in the `/app/ldif/` folder. The files will processed in order they apper in the folder.

First of all it extracts the `dn: ` value from the file to have the dn of the object. Next it tries to read the current value by an ldapsearch query. When there is no result it will add the ldif using the `ldapadd` command.

When ldapsearch delivers a resposne, the responsing ldif is compared (via https://github.com/nxadm/ldifdiff/ ). When there are changes required the changes are applied via `ldapmodify`.

As passwords cannot compared easly the password for useres are updated every time the job runs...

## Configuration

The Bitnami Docker OpenLDAP can be easily setup with the following environment variables:

- `LDAP_URI`: The URI to the LDAP server. Default: ldap://openldap:389/
- `LDAP_DOMAIN`: The "domain" of the LDAP in the format `example.org`. Used to build up `LDAP_BASE_DN` and also valid in template. **Required**
- `LDAP_BASE_DN`: LDAP database root node of the LDAP tree. Example: `dc=example,dc=org`. When not filled in it's generated from `LDAP-DOMAIN`
- `LDAP_ADMIN_USER`: admin user to connect LDAP server. Default: `cn=admin,${LDAP_BASE_DN}`
- `LDAP_ADMIN_PASSWORD`: admin user password used to authenticate. **Required**
- `LDAP_CUSTOM_[a-zA-Z0-9_-]*`: Additional custom variables used in template replacement.

## Template replacements

In the template replacement following environment variables can be used:

- `LDAP_DOMAIN`
- `LDAP_BASE_DN`
- `LDAP_CUSTOM_[a-zA-Z0-9_-]*`

## Kudos

Kudos go to https://github.com/osixia/ for their great `log-helper` script from `https://github.com/osixia/docker-light-baseimage` - I use it here.
Also for their openldap container: https://github.com/osixia/docker-openldap

Kudos also go to nxadm for the ldap-ldiff tool: https://github.com/nxadm/ldifdiff/