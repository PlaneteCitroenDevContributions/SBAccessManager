#! /bin/bash

HERE=$( dirname "$0" )

source "../${HERE}/dav_config.env"

ics_url='https://cloud.forumtestplanetecitroen.fr/remote.php/dav/calendars/servicebox/personal/sabredav-08153cd3-9112-46fb-b7c8-cceb7c58564e.ics'

vcal=$(
    curl -u ${CALDAV_USERNAME}:${CALDAV_PASSWORD} -H 'Accept: text/calendar' -H 'Accept-Charset: utf-8, iso-8859-1;q=0.5' "${ics_url}" | \
	sed -z 's/\r\n\ //g'
    )

