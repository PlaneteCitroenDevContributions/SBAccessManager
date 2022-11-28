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

declare -a appointedDNs_array=()

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
    lowercase_ldap_mail=$( tr '[:upper:]' '[:lower:]' <<< ${ldap_mail} )
    if [[ "${lowercase_mailto}" != "${lowercase_ldap_mail}" ]]
    then
	echo "INTERNAL ERROR: Searched for \"${mailto}\" and found \"${ldap_mail}\" in ldap.
Strings \"${lowercase_mailto}\" and \"${lowercase_ldap_mail}\" dos not match" 1>&2
	continue
	# NOT REACHED
    fi
    
    dn=$( sed -n -e '/^dn: /s/^dn: //p' <<< ${dn_search_result} )

    appointedDNs_array+=( "${dn}" )

done

allowed_DNs_ldap_search_result=$(
    ${dsidm_cmd} group members "${ALLOWING_LDAP_GROUP_NAME}" | \
	sed -n -e '/^dn: /s/^dn: //p' )
echo "${allowed_DNs_ldap_search_result}" | readarray allowedDNs_array
															      
#
# allow new users who reserved and are not already allowed
#

appointed_minus_allowed_DNs=$(
    
    for dn in "${allowedDNs_array[@]}" "${allowedDNs_array[@]}" "${appointedDNs_array[@]}"
    do
	echo "${dn}"
    done | \
    sort | \
    uniq -u
)
echo "${appointed_minus_allowed_DNs}" | readarray new_DNs_array

for dn in "${new_DNs_array[@]}"
do
    grantServiceBoxAccess "${dn}"
done

#
# revoke all users who did not reserve and are currently allowed
#

allowed_DNs_minus_appointed=$(
    
    for dn in "${appointedDNs_array[@]}" "${appointedDNs_array[@]}" "${allowedDNs_array[@]}"
    do
	echo "${dn}"
    done | \
    sort | \
    uniq -u
)
echo "${allowed_DNs_minus_appointed}" | readarray terminated_DNs_array

for dn in "${terminated_DNs_array[@]}"
do
    revokeServiceBoxAccess "${dn}"
done

(
    echo "INFO: currently allowed DNs"
    ${dsidm_cmd} group members "${ALLOWING_LDAP_GROUP_NAME}"
) 1>&2
