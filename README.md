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
  01-OU-serviceaccounts.ldif: |-
    dn: ou=serviceaccounts,{{ LDAP_BASE_DN }}
    objectClass: organizationalUnit
    ou: users

  02-USER-demo-services.ldif: |-
    dn: uid=demo-service,ou=serviceaccounts,{{ LDAP_BASE_DN }}
    objectClass: account
    objectClass: simpleSecurityObject
    objectClass: top
    uid: demo-service
    userPassword: {{ LDAP_CUSTOM_DEMO_PASSWORD_ENCRYPTED }}

  07-USER-demo-services-MEMBER-administrators.ldif: |-
    # validateCmd: ! grep -q "member: uid=demo-service,ou=serviceaccounts,{{ LDAP_BASE_DN }}" ${curLDIFFile}
    dn: cn=administrators,ou=groups,{{ LDAP_BASE_DN }}
    changetype: modify
    add: member
    member: uid=demo-service,ou=serviceaccounts,{{ LDAP_BASE_DN }}


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

As passwords cannot be compared easly the password for useres are updated every time the job runs.

To allow 'modifications' on existing entries you are able to add files containing a `changetype`. These files also require an `# validateCmd: ` line. Take this example:

```
# validateCmd: ! grep -q "member: uid=demo-service,ou=serviceaccounts,{{ LDAP_BASE_DN }}" ${curLDIFFile}
dn: cn=administrators,ou=groups,{{ LDAP_BASE_DN }}
changetype: modify
add: member
member: uid=demo-service,ou=serviceaccounts,{{ LDAP_BASE_DN }}
```

When processing a file with a `changetype` it searches for the `#validateCmd: ` line. The dn will be exported and the command specified will be started. A return of `0` indicates everything is fine, `1` means the file will be applied via ldapmodify. All other codes indecate an error. With `!` the meaning of `0` and `1` is swapped.
In this sample it executes a `grep` command to look for the required 'membership' line. When it is present, everything is fine. If not, it will be added.


## Configuration

The OpenLDAP LDIF applier can be easily setup with the following environment variables:

- `LDAP_URI`: The URI to the LDAP server. Default: ldap://openldap:389/
- `LDAP_DOMAIN`: The "domain" of the LDAP in the format `example.org`. Used to build up `LDAP_BASE_DN` and also valid in template. **Required**
- `LDAP_BASE_DN`: LDAP database root node of the LDAP tree. Example: `dc=example,dc=org`. When not filled in it's generated from `LDAP-DOMAIN`
- `LDAP_ADMIN_USER`: admin user to connect LDAP server. Default: `cn=admin,${LDAP_BASE_DN}`
- `LDAP_ADMIN_PASSWORD`: admin user password used to authenticate. **Required**
- `LDAP_CUSTOM_[a-zA-Z0-9_-]*`: Additional custom variables used in template replacement.
- `LDAP_CUSTOM_[a-zA-Z0-9_-]_PASSWORD_ENCRYPTED`: When not defined, it searches for a matching `LDAP_CUSTOM_[a-zA-Z0-9_-]_PASSWORD` variable and encrypts it with `slappasswd -s "${VALUE}"`.

## Template replacements

In the template replacement following environment variables can be used:

- `LDAP_DOMAIN`
- `LDAP_BASE_DN`
- `LDAP_CUSTOM_[a-zA-Z0-9_-]*`

## Kudos

Kudos go to https://github.com/osixia/ for their great `log-helper` script from `https://github.com/osixia/docker-light-baseimage` - I use it here.
Also for their openldap container: https://github.com/osixia/docker-openldap

Kudos also go to nxadm for the ldap-ldiff tool: https://github.com/nxadm/ldifdiff/