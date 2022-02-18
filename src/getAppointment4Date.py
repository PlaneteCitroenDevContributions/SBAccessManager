import sys
import caldav
import datetime

caldav_url = 'https://cloud.forumtestplanetecitroen.fr/remote.php/dav'
username = 'bernhara_admin'
password = 'gLNm7-pGM8L-NPc9T-85jdL-9fnyg'
servicebox_calendar_name = 'AccesServiceBox'

username = 'servicebox'
password = '3XQJ3-C5Mba-WTsHb-95AnZ-WSNBz'
servicebox_calendar_name = 'AccesServiceBox'


def main ():
    
    client = caldav.DAVClient(url=caldav_url, username=username, password=password)
    my_principal = client.principal()

    calendars = my_principal.calendars()
    
    servicebox_calendar = None
    for c in calendars:
        print ('Found calendar ' + c.name, file=sys.stderr)
        if c.name == servicebox_calendar_name:
            servicebox_calendar = c
            break
    
    if not servicebox_calendar:
        print ('Calendar ' + servicebox_calendar_name + ' not found', file=sys.stderr)
        return []
    
    ## Let's search for the newly added event.
    ## (this may fail if the server doesn't support expand)
    print("Here is some icalendar data for the next 60 minutes:")
    start = datetime.datetime.now()
    time_range = datetime.timedelta(minutes=60)
    end = start + time_range
    events_fetched = []
    try:
    
        events_fetched = servicebox_calendar.date_search(start=start, end=end, expand=True)

    except:
        print("Your calendar server does apparently not support expanded search", file=sys.stderr)


    for event in events_fetched:
        print (event)
        event_data = event.data
        print ('======================================')
        print (event_data)
        event_vobject = event.vobject_instance
        
    
    
    
    
    return


if __name__ == '__main__':
    main ()