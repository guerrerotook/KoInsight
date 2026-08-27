import { BookWithData, PageStat } from '@koinsight/common/types';
import { Flex, Switch } from '@mantine/core';
import { startOfDay } from 'date-fns/startOfDay';
import { sum } from 'ramda';
import { JSX, useMemo, useState } from 'react';
import { Calendar, CalendarEvent } from '../../components/calendar/calendar';
import { CalendarBookDay } from '../../components/calendar/calendar-book-day';

const MINIMUM_SESSION_DURATION = 60;

type BookPageCalendarProps = {
  book: BookWithData;
};

type DayData = {
  events: PageStat[];
};

export function BookPageCalendar({ book }: BookPageCalendarProps): JSX.Element {
  const [hideShortSessions, setHideShortSessions] = useState(false);

  const calendarEvents = useMemo(() => {
    const grouped = book.stats.reduce<Record<string, CalendarEvent<DayData>>>((acc, event) => {
      const date = startOfDay(event.start_time);
      const key = date.toISOString();
      acc[key] = acc[key] || { date, data: { events: [] } };
      acc[key].data = acc[key]?.data?.events
        ? { events: [...acc[key].data.events, event] }
        : { events: [event] };

      return acc;
    }, {});

    if (!hideShortSessions) {
      return grouped;
    }

    return Object.entries(grouped).reduce<Record<string, CalendarEvent<DayData>>>(
      (acc, [key, entry]) => {
        const total = sum((entry.data?.events ?? []).map((event) => event.duration));

        if (total >= MINIMUM_SESSION_DURATION) {
          acc[key] = entry;
        }

        return acc;
      },
      {}
    );
  }, [book.stats, hideShortSessions]);

  return (
    <>
      <Flex justify="flex-end" mb="sm">
        <Switch
          label="Hide entries under a minute"
          checked={hideShortSessions}
          onChange={(event) => setHideShortSessions(event.currentTarget.checked)}
        />
      </Flex>
      <Calendar<DayData>
        events={calendarEvents}
        dayRenderer={(data) => <CalendarBookDay book={book} data={data} />}
      />
    </>
  );
}
