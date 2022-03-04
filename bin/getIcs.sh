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
	curl -u ${CALDAV_USERNAME}:${CALDAV_PASSWORD} -H 'Accept: text/calendar' -H 'Accept-Charset: utf-8' "${ics_url}" | \
	    sed -z 's/\r\n\ //g'
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

    iso_organizer_line=$( echo "${organizer_line}" | iconv -f UTF8 -t ISO-8859-1 )

    organizer_data=$(
	echo "${organizer_line}" | sed -e 's/ORGANIZER;//' -e 's/\r$//'
	     )

    echo "${organizer_data}" > /tmp/zz.txt
    cn=$( echo "${organizer_data}" | sed -e 's/CN=\(.*\):mailto:.*$/\1/' )
    mailto=$( echo "${organizer_data}" | sed -e 's/.*:mailto:\(.*\)$/\1/' )

    echo ${cn}
    echo ${mailto}
    echo

    exit
done

