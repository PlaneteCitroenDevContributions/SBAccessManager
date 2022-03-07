#! /bin/bash

HERE=$( dirname "$0" )
PROJECT_ROOT_DIR="${HERE}/.."

export LANG='en_US.utf8'

source "${PROJECT_ROOT_DIR}/dav_config.env"

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

ics_url_list=$(
    ${PYTHON_BIN} "${PROJECT_ROOT_DIR}/src/getAppointments4Date.py" 2>/dev/null
)

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

    echo ${displayName}
    echo ${mailto}

done

#
# KEEP:
# ldapsearch -x -b 'ou=people,dc=planetecitroen,dc=fr' -H ldap://ldap:3389  'mail=raphael.bernhard@orange.fr' dn 2>/dev/null
# ldapsearch -x -b 'ou=people,dc=planetecitroen,dc=fr' -H ldap://ldap:3389 -z 1 'mail=raphael.bernhard@orange.fr' dn mail

