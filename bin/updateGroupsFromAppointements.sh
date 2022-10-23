#! /bin/bash

HERE=$( dirname "$0" )
PROJECT_ROOT_DIR="${HERE}/.."

if [[ -n "${SHELL_DEBUG}" ]]
then
    set -x
fi

dsidm_cmd="dsidm --pwdfile /etc/pwdfile.txt pcds"
ldapsearch_cmd="ldapsearch -x -b ou=people,dc=planetecitroen,dc=fr -H ldap://ldap:3389"

export LANG='en_US.utf8'

: ${ALLOWING_LDAP_GROUP_NAME:='ServiceBoxAllowed'}

: ${PYTHON_BIN:="${PROJECT_ROOT_DIR}/.venv/bin/python"}

getVCalData ()
{
    ics_url="$1"

    sanitized_url=$(
	echo "${ics_url}" | tr --delete '\r'
	)

    vcal_data=$(
	test -r /tmp/response && rm /tmp/response.txt
	code=$(
	    curl \
	       --silent --show-error -w '%{http_code}' -o /tmp/response.txt \
	       -u ${CALDAV_USERNAME}:${CALDAV_PASSWORD} -H 'Accept: text/calendar' -H 'Accept-Charset: utf-8' "${ics_url}" )
	# put everything on a single line
	sed -z 's/\r\n\ //g' /tmp/response.txt
    )

    echo "${vcal_data}"
}

grantServiceBoxAccess ()
{
    ldap_dn="$1"

    ${dsidm_cmd} group add_member "${ALLOWING_LDAP_GROUP_NAME}"  "${ldap_dn}"
    
}

revokeServiceBoxAccess ()
{
    ldap_dn="$1"

    ${dsidm_cmd} group remove_member "${ALLOWING_LDAP_GROUP_NAME}"  "${ldap_dn}"
}


ics_url_list=$(
    ${PYTHON_BIN} "${PROJECT_ROOT_DIR}/src/getAppointments4Date.py" 2>/dev/null
)

#
# search for all users who reserved
#

allowedLdapDNs=''
for ics_url in $( echo "${ics_url_list}" )
do

    vcal_data=$( getVCalData ${ics_url} )

    organizer_line=$(
	echo "${vcal_data}" | grep -e '^ORGANIZER;'
		  )

    organizer_data=$(
	echo "${organizer_line}" | sed -e 's/ORGANIZER;//' -e 's/\r$//'
	     )

    displayName=$( echo "${organizer_data}" | sed -e 's/CN=\(.*\):mailto:.*$/\1/' )
    mailto=$( echo "${organizer_data}" | sed -e 's/.*:mailto:\(.*\)$/\1/' )

    (
	echo "INFO: display Name \"${displayName}\" with email \"${mailto}\" has reserved"
    ) 1>&2

    # retrieve user description (dn + mail) in LDAP, based on his email address (mailto)
    dn_search_result=$(
	${ldapsearch_cmd} -z 1 "mail=${mailto}" dn mail
    )
    if grep -q '--regexp=^mail:' <<< ${dn_search_result}
    then
	# ldap search result OK
	:
    else
	echo "INTERNAL ERROR: Could not file \"${mailto}\" in ldap" 1>&2
	continue
	# NOT REACHED
    fi

    #
    # for security, we check that the retrieved mail is what we searched for
    #
    ldap_mail=$( sed -n -e '/^mail: /s/^mail: //p' <<< ${dn_search_result} )
    lowercase_mailto=$( tr '[:upper:]' '[:lower:]' <<< ${mailto} )
    lowercase_ldap_mail$( tr '[:upper:]' '[:lower:]' <<< ${ldap_mail} )
    if [[ "${lowercase_mailto}" != "${lowercase_ldap_mail}" ]]
    then
	echo "INTERNAL ERROR: Searched for \"${mailto}\" and found \"${ldap_mail}\" in ldap.
Strings \"${lowercase_mailto}\" and \"${lowercase_ldap_mail}\" dos not match" 1>&2
	continue
	# NOT REACHED
    fi
    
    ldap_dn=$( sed -n -e '/^dn: /s/^dn: //p' <<< ${dn_search_result} )

    allowedLdapDNs="${allowedLdapDNs} ${ldap_dn}"

done

# FIXME: rename this var
already_allowed_dns=$( ${dsidm_cmd} group members "${ALLOWING_LDAP_GROUP_NAME}" | sed -e '/^dn: /s/^dn: //' )

#
# allow new users who reserved and are not already allowed
#
for dn in ${allowedLdapDNs}
do
    if grep -q "${dn}" <<< ${already_allowed_dns}
    then
	# already allowd => skip
	:
    else
	grantServiceBoxAccess "${dn}"
    fi
done

#
# revoke all users who did not reserve and are currently allowed
#

for dn in ${already_allowed_dns}
do
    if grep -q "${dn}" <<< ${allowedLdapDNs}
    then
	:
    else
	revokeServiceBoxAccess "${dn}"
    fi
done

(
    echo "INFO: currently allowed DNs"
    ${dsidm_cmd} group members "${ALLOWING_LDAP_GROUP_NAME}"
) 1>&2

