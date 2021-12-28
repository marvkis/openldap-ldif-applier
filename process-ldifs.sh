#!/bin/ash

PATH="/app/bin/:$PATH"

#set -x
log-helper level eq trace && set -x

function get_ldap_base_dn() {
    # if LDAP_BASE_DN is empty set value from LDAP_DOMAIN
    if [ -z "$LDAP_BASE_DN" ]; then
        OLD_IFS="${IFS}"
        IFS='.'
        for i in ${LDAP_DOMAIN}; do
            EXT="dc=$i,"
            LDAP_BASE_DN=$LDAP_BASE_DN$EXT
        done
        IFS="${OLD_IFS}"
        LDAP_BASE_DN=${LDAP_BASE_DN::-1}
    fi
    # Check that LDAP_BASE_DN and LDAP_DOMAIN are in sync
    domain_from_base_dn=$(echo $LDAP_BASE_DN | tr ',' '\n' | sed -e 's/^.*=//' | tr '\n' '.' | sed -e 's/\.$//')
    if `echo "$domain_from_base_dn" | egrep -q ".*$LDAP_DOMAIN\$" || echo $LDAP_DOMAIN | egrep -q ".*$domain_from_base_dn\$"`; then
        : # pass
    else
        log-helper error "Error: domain $domain_from_base_dn derived from LDAP_BASE_DN $LDAP_BASE_DN does not match LDAP_DOMAIN $LDAP_DOMAIN"
        exit 1
    fi
}

# initialze env
get_ldap_base_dn

if [[ -z "${LDAP_URI}" ]]; then
    export LDAP_URI="ldap://openldap:389/"
fi

if [[ -z "${LDAP_ADMIN_USER}" ]]; then
    export LDAP_ADMIN_USER="cn=admin,${LDAP_BASE_DN}"
fi


# check if we can connect to ldap... (startup dependency sequence)
conntestcount=0
until ldapsearch -x -H "${LDAP_URI}" -D "${LDAP_ADMIN_USER}" -w "${LDAP_ADMIN_PASSWORD}" -b "${LDAP_BASE_DN}" -s base >/dev/null; do
    log-helper info "waiting for openldap to become ready"
    sleep 2
    let conntestcount+=1
    if [[ $conntestcount -gt 20 ]]; then
        log-helper error "Timout waiting for openldap"
        exit -2
    fi
done


# business logic
set +e
for LDIF_FILE in /app/ldif/*.ldif; do
    if [[ ! -e "${LDIF_FILE}" ]]; then
        log-helper info "No *.ldif files found in /app/ldif/"
        exit 0
    fi
    log-helper debug "Processing file ${LDIF_FILE}"

    cp ${LDIF_FILE} /tmp/temp-$$.ldif
    sed -i "s|{{ LDAP_BASE_DN }}|${LDAP_BASE_DN}|g" /tmp/temp-$$.ldif
    sed -i "s|{{ LDAP_DOMAIN }}|${LDAP_DOMAIN}|g" /tmp/temp-$$.ldif

    REPS="$(grep -o -e "{{ LDAP_CUSTOM_[a-zA-Z0-9_-]* }}" /tmp/temp-$$.ldif)"
    OLD_IFS="${IFS}"
    IFS=$'\n'
    for REP in $REPS; do
        [[ -z "${REP}" ]] && continue
        VAR="${REP: 3:-3}"
        VALUE="$(eval echo \${${VAR}:-VARIABLE_IS_UNSET})"
        if [[ "${VALUE}" = "VARIABLE_IS_UNSET" ]]; then
            if [[ "${VAR}" =~  "_PASSWORD_ENCRYPTED" ]]; then
                VALUE="$(eval echo \${${VAR: 0:-10}:-VARIABLE_IS_UNSET})"
                if [[ "${VALUE}" = "VARIABLE_IS_UNSET" ]]; then
                    log-helper error "Error processing ${LDIF_FILE##*/}: Replacement for ${REP} / ${VAR: 0:-10} is not defined!"
                    continue 2
                fi
                VALUE="$(slappasswd -s "${VALUE}")"
                sed -i "s|${REP}|${VALUE}|g" /tmp/temp-$$.ldif
            else
                log-helper error "Error processing ${LDIF_FILE##*/}: Replacement for ${REP} is not defined!"
                continue 2
            fi
        else
            sed -i "s|${REP}|${VALUE}|g" /tmp/temp-$$.ldif
        fi
    done
    IFS="${OLD_IFS}"

    hasChangeType=$(grep -q "changetype: " /tmp/temp-$$.ldif && echo 1 || echo 0)
    dn="$(grep '^dn: ' /tmp/temp-$$.ldif)"
    curLDIF="$(ldapsearch -o ldif-wrap=no -x -H "${LDAP_URI}" -D "${LDAP_ADMIN_USER}" -w "${LDAP_ADMIN_PASSWORD}" -b "${dn/dn: /}" -s base -LLL 2>&1 )"
    ret=$?
    if [[ "$ret" -eq 0 ]]; then
        # ldif was created
        echo "${curLDIF}" > /tmp/temp-$$-cur.ldif
        if [[ "$hasChangeType" == 0 ]]; then
            LDIF_MODIFY="$(/app/bin/ldifdiff /tmp/temp-$$.ldif /tmp/temp-$$-cur.ldif)"
            if [[ ! -z "${LDIF_MODIFY}" ]]; then
                MODS="$(echo "${LDIF_MODIFY}" | grep "changetype: " -A 1)"
                if [[ "$MODS" == $'changetype: modify\nreplace: userPassword' ]]; then
                    echo -e "Updating password for ${LDIF_FILE##*/}" | log-helper info
                else
                    echo -e "We have to update ${LDIF_FILE##*/}:\ncurrent:\n\n${curLDIF}\n\ntarget:\n\n$(cat /tmp/temp-$$.ldif)\n\ndelta:\n\n${LDIF_MODIFY}" | log-helper info
                fi
                echo "${LDIF_MODIFY}" > /tmp/temp-$$-modify.ldif
                LMR="$(ldapmodify -H "${LDAP_URI}" -D "${LDAP_ADMIN_USER}" -w "$LDAP_ADMIN_PASSWORD" -f /tmp/temp-$$-modify.ldif 2>&1)"
                ret=$?
                if [[ "$ret" -ne 0 ]]; then
                    echo "${LMR}" | log-helper error
                fi
            fi
        else
            # this is a patch file...
            valcmd="$(grep '^# validateCmd:' /tmp/temp-$$.ldif | cut -c 15-)"
            doit=0
            if [ -z "${valcmd}" ]; then
                log-helper debug "No # validateCmd: found in ${LDIF_FILE##*/}"
                doit=1
            else
                export curLDIFFile=/tmp/temp-$$-cur.ldif
                # is command prefixed with ! (not?)
                if [[ "${valcmd}" =~ '^[ ]*!' ]]; then
                    # remove 'not' ('!') and execute command; map 0 -> 1; 1 -> 0 and all other codes untouched
                    cmdRet="$(eval ${valcmd/[ ]*!/}) 2>&1"
                    ret=$?
                    if [[ $ret -eq 0 ]]; then
                        ret=1
                    elif [[ $ret -eq 1 ]]; then
                        ret=0
                    fi
                else
                    cmdRet="$(eval ${valcmd}) 2>&1"
                    ret=$?
                fi
                if [[ $ret -eq 0 ]]; then
                    doit=1
                elif [[ $ret -eq 1 ]]; then
                    log-helper debug "Command ${valcmd} return FALSE - not applying ${LDIF_FILE##*/}"
                else
                    echo -e "Command ${valcmd} returned ${ret}:\n\n${cmdRet}" | log-helper error
                fi
            fi
            if [[ "${doit}" -eq 1 ]]; then
                log-helper info "applying ${LDIF_FILE##*/}"
                LMR="$(ldapmodify -H "${LDAP_URI}" -D "${LDAP_ADMIN_USER}" -w "$LDAP_ADMIN_PASSWORD" -f /tmp/temp-$$.ldif 2>&1)"
                ret=$?
                if [[ "$ret" -ne 0 ]]; then
                    echo "${LMR}" | log-helper error
                fi
            fi
            $vali
        fi
    elif [[ "$ret" -eq 32 ]]; then
        # DN not existant
        log-helper info "Adding ${LDIF_FILE##*/}"
        ldapadd -H "${LDAP_URI}" -D "${LDAP_ADMIN_USER}" -w "${LDAP_ADMIN_PASSWORD}" -f /tmp/temp-$$.ldif 2>&1 | log-helper error
    else
        echo -e "Error reading data for ${LDIF_FILE##*/} / DN: ${dn/dn: /}\nldapsearch exited with ${ret}:\n\n${curLDIF}" | log-helper error
    fi

done

rm /tmp/temp-$$*.ldif

