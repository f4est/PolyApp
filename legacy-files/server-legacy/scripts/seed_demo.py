from datetime import date, datetime, timedelta
from sqlmodel import Session, select
from app.main import (
    engine,
    User,
    NewsPost,
    NewsComment,
    NewsLike,
    RequestTicket,
    AttendanceRecord,
    GradeRecord,
    ExamUpload,
    ExamGrade,
    JournalGroup,
    JournalStudent,
    JournalDate,
    TeacherGroupAssignment,
    hash_password,
    REQUEST_TYPES,
    REQUEST_STATUSES,
)

DEMO_PASSWORD = "Demo1234"

DEMO_USERS = [
    {"role": "admin", "full_name": "Admin Demo", "email": "admin@demo.local"},
    {"role": "student", "full_name": "Student Demo", "email": "student@demo.local", "student_group": "P22-3E"},
    {"role": "teacher", "full_name": "Teacher Demo", "email": "teacher@demo.local", "teacher_name": "Teacher Demo"},
    {"role": "parent", "full_name": "Parent Demo", "email": "parent@demo.local"},
    {"role": "request_handler", "full_name": "Handler Demo", "email": "handler@demo.local"},
    {"role": "smm", "full_name": "SMM Demo", "email": "smm@demo.local"},
]


def get_or_create_user(session: Session, payload: dict) -> User:
    existing = session.exec(select(User).where(User.email == payload["email"])).first()
    if existing:
        return existing
    user = User(
        role=payload["role"],
        full_name=payload["full_name"],
        email=payload["email"],
        password_hash=hash_password(DEMO_PASSWORD),
        student_group=payload.get("student_group"),
        teacher_name=payload.get("teacher_name"),
    )
    session.add(user)
    session.commit()
    session.refresh(user)
    return user


def main() -> None:
    with Session(engine) as session:
        users = {u["role"]: get_or_create_user(session, u) for u in DEMO_USERS}

        group = "P22-3E"
        if not session.exec(select(JournalGroup).where(JournalGroup.name == group)).first():
            session.add(JournalGroup(name=group))
            session.commit()

        students = ["Ivan Petrov", "Anna Sidorova", "Alina Karim", "Nikita Smirnov"]
        for name in students:
            if not session.exec(
                select(JournalStudent).where(JournalStudent.group_name == group, JournalStudent.student_name == name)
            ).first():
                session.add(JournalStudent(group_name=group, student_name=name))
        session.commit()

        today = date.today()
        dates = [today - timedelta(days=2), today - timedelta(days=1), today]
        for d in dates:
            if not session.exec(
                select(JournalDate).where(JournalDate.group_name == group, JournalDate.class_date == d)
            ).first():
                session.add(JournalDate(group_name=group, class_date=d))
        session.commit()

        for d in dates:
            for name in students:
                if not session.exec(
                    select(AttendanceRecord).where(
                        AttendanceRecord.group_name == group,
                        AttendanceRecord.class_date == d,
                        AttendanceRecord.student_name == name,
                    )
                ).first():
                    session.add(
                        AttendanceRecord(
                            group_name=group,
                            class_date=d,
                            student_name=name,
                            present=True,
                            teacher_id=users["teacher"].id,
                        )
                    )
        session.commit()

        for d in dates:
            for name in students:
                if not session.exec(
                    select(GradeRecord).where(
                        GradeRecord.group_name == group,
                        GradeRecord.class_date == d,
                        GradeRecord.student_name == name,
                    )
                ).first():
                    session.add(
                        GradeRecord(
                            group_name=group,
                            class_date=d,
                            student_name=name,
                            grade=85,
                            teacher_id=users["teacher"].id,
                        )
                    )
        session.commit()

        if not session.exec(select(TeacherGroupAssignment).where(TeacherGroupAssignment.group_name == group)).first():
            session.add(
                TeacherGroupAssignment(
                    teacher_id=users["teacher"].id,
                    group_name=group,
                    subject="Math",
                )
            )
            session.commit()

        post = session.exec(select(NewsPost).where(NewsPost.title == "Welcome" )).first()
        if not post:
            post = NewsPost(
                title="Welcome",
                body="Welcome to PolyApp demo feed!",
                author_id=users["smm"].id,
            )
            session.add(post)
            session.commit()
            session.refresh(post)

        if not session.exec(select(NewsComment).where(NewsComment.post_id == post.id)).first():
            session.add(
                NewsComment(
                    post_id=post.id,
                    user_id=users["student"].id,
                    text="Great to be here!",
                )
            )
            session.commit()

        if not session.exec(select(NewsLike).where(NewsLike.post_id == post.id, NewsLike.user_id == users["student"].id)).first():
            session.add(NewsLike(post_id=post.id, user_id=users["student"].id))
            session.commit()

        if not session.exec(select(RequestTicket)).first():
            session.add(
                RequestTicket(
                    student_id=users["student"].id,
                    request_type=REQUEST_TYPES[0],
                    status=REQUEST_STATUSES[0],
                    details="Demo request",
                )
            )
            session.commit()

        upload = session.exec(select(ExamUpload).where(ExamUpload.exam_name == "Math Final")).first()
        if not upload:
            upload = ExamUpload(
                group_name=group,
                exam_name="Math Final",
                filename="demo.xlsx",
                rows_count=len(students),
                teacher_id=users["teacher"].id,
            )
            session.add(upload)
            session.commit()
            session.refresh(upload)

        for name in students:
            if not session.exec(
                select(ExamGrade).where(ExamGrade.exam_name == "Math Final", ExamGrade.student_name == name)
            ).first():
                session.add(
                    ExamGrade(
                        group_name=group,
                        exam_name="Math Final",
                        student_name=name,
                        grade=90,
                        teacher_id=users["teacher"].id,
                        upload_id=upload.id,
                    )
                )
        session.commit()

    print("Demo data seeded. Password for all demo users:", DEMO_PASSWORD)


if __name__ == "__main__":
    main()
