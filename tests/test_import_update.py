import os
import tempfile
import csv
import unittest

from app import app, db, Member, import_members_from_csv


class ImportMemberUpdateTestCase(unittest.TestCase):
    def setUp(self):
        self.app_context = app.app_context()
        self.app_context.push()
        db.drop_all()
        db.create_all()

    def tearDown(self):
        db.session.remove()
        db.drop_all()
        self.app_context.pop()

    def _create_csv(self, rows):
        fd, path = tempfile.mkstemp(suffix='.csv')
        with os.fdopen(fd, 'w', newline='') as f:
            writer = csv.DictWriter(
                f,
                fieldnames=[
                    'Registration_Badge_ID',
                    'First_Name',
                    'Last_Name',
                    'Organization',
                    'Work Email Address Do not use personal',
                    'Is_Member?',
                ],
            )
            writer.writeheader()
            for row in rows:
                writer.writerow(row)
        return path

    def test_existing_member_updated_and_re_eligible(self):
        csv_path = self._create_csv([
            {
                'Registration_Badge_ID': 'TEST1',
                'First_Name': 'John',
                'Last_Name': 'Doe',
                'Organization': 'Org1',
                'Work Email Address Do not use personal': 'john@example.com',
                'Is_Member?': 'Yes',
            }
        ])
        import_members_from_csv(csv_path, use_flash=False)
        os.remove(csv_path)

        member = Member.query.filter_by(registration_badge_id='TEST1').first()
        self.assertEqual(member.first_name, 'John')
        self.assertTrue(member.eligible_for_drawing)

        member.eligible_for_drawing = False
        db.session.commit()

        csv_path = self._create_csv([
            {
                'Registration_Badge_ID': 'TEST1',
                'First_Name': 'Johnny',
                'Last_Name': 'Doette',
                'Organization': 'OrgUpdated',
                'Work Email Address Do not use personal': 'johnny@example.com',
                'Is_Member?': 'Yes',
            }
        ])
        import_members_from_csv(csv_path, use_flash=False)
        os.remove(csv_path)

        self.assertEqual(Member.query.count(), 1)
        updated = Member.query.filter_by(registration_badge_id='TEST1').first()
        self.assertEqual(updated.first_name, 'Johnny')
        self.assertEqual(updated.last_name, 'Doette')
        self.assertEqual(updated.organization, 'OrgUpdated')
        self.assertEqual(updated.email, 'johnny@example.com')
        self.assertTrue(updated.eligible_for_drawing)


if __name__ == '__main__':
    unittest.main()
