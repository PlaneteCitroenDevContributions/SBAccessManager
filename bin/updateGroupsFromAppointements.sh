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
	       -u ${CALDAV_USERNAME}:${CALDAV_PASSWORD} -H 'Accept: text/calendar' -H 'Accept-Charset: utf-8' "${ics_url}"'?export' )
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


if [[ -z "${TEST_ICS_URL_LIST}" ]]
then
    ics_url_list=$(
	${PYTHON_BIN} "${PROJECT_ROOT_DIR}/src/getAppointments4Date.py" 2>/dev/null
    )
else
    ics_url_list="${TEST_ICS_URL_LIST}"
fi

#
# search in appointments if there is one which enables reservation
#
for ics_url in $( echo "${ics_url_list}" )
do

    vcal_data=$( getVCalData ${ics_url} )

    organizer_line=$(
	echo "${vcal_data}" | grep -e '^ORGANIZER;'
		  )
    if [[ -z "${organizer_line}" ]]
    then
	(
	    echo "INFO: found appointment without ORGANIZER => it is myself (\"${CALDAV_USERNAME}\")"
	) 1>&2


	#
	# TODO: this case enables reservation
	# NYI
    fi

done

#
# search for all users who reserved
#

declare -a appointed_DNs_array=()

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
	echo "INFO: found appointment for display Name \"${displayName}\" with email \"${mailto}\""
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

    appointed_DNs_array+=( "${dn}" )

done

(
    echo "INFO: currently appointed DNs"
    for dn in "${appointed_DNs_array[@]}"
    do
	echo "	\"${dn}\""
    done
) 1>&2

#
# TODO:
# check if a predefined DN (a manager?) has appointment currently reserver
# if not, no new users can be allowed => allowed_DNs_array should remain empty
#

allowed_DNs_ldap_search_result=$(

    # dsidm may return line with empty DNs => remove these empty lines

    ${dsidm_cmd} group members "${ALLOWING_LDAP_GROUP_NAME}" | \
	sed -n -e '/^dn: /s/^dn: //p' | \
	sed -e '/^[ \t]*$/d' )
# store result in array
declare -a allowed_DNs_array=()
while IFS= read -r line; do
    # skip eventual empty lines
    if [[ -n "${line}" ]]
    then
	allowed_DNs_array+=( "${line}" )
    fi
done <<< ${allowed_DNs_ldap_search_result}
#
# allow new users who reserved and are not already allowed
#

appointed_minus_allowed_DNs=$(
    
    for dn in "${allowed_DNs_array[@]}" "${allowed_DNs_array[@]}" "${appointed_DNs_array[@]}"
    do
	echo "${dn}"
    done | \
    sort | \
    uniq -u
)
# store result in array
declare -a  new_DNs_array=()
while IFS= read -r line; do
    # skip eventual empty lines
    if [[ -n "${line}" ]]
    then
	new_DNs_array+=( "${line}" )
    fi
done <<< ${appointed_minus_allowed_DNs}



#
# grant access to appointed DNs not already granted
#

for dn in "${new_DNs_array[@]}"
do
    grantServiceBoxAccess "${dn}"
    (
	echo "INFO: granted acces to DN \"${dn}\""
    ) 1>&2
done

#
# revoke all users who did not reserve and are currently allowed
#

allowed_DNs_minus_appointed=$(
    
    for dn in "${appointed_DNs_array[@]}" "${appointed_DNs_array[@]}" "${allowed_DNs_array[@]}"
    do
	echo "${dn}"
    done | \
    sort | \
    uniq -u
)
# store result in array
declare -a  terminated_DNs_array=()
while IFS= read -r line; do
    # skip eventual empty lines
    if [[ -n "${line}" ]]
    then
	terminated_DNs_array+=( "${line}" )
    fi
done <<< ${allowed_DNs_minus_appointed}

for dn in "${terminated_DNs_array[@]}"
do
    revokeServiceBoxAccess "${dn}"
    (
	echo "INFO: revoked acces to DN \"${dn}\""
    ) 1>&2
done

(
    echo "INFO: current members of LDAP group \"${ALLOWING_LDAP_GROUP_NAME}\""
    ${dsidm_cmd} group members "${ALLOWING_LDAP_GROUP_NAME}" | sed -e 's/^/\t==>/'
) 1>&2
