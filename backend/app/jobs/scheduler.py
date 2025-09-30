from apscheduler.schedulers.blocking import BlockingScheduler
sched = BlockingScheduler()
@sched.scheduled_job('interval', hours=6)
def ping():
    print("worker heartbeat")
if __name__ == "__main__":
    sched.start()
