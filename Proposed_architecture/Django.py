from django.core.validators import RegexValidator
from rest_framework import serializers

from .models import Student


class StudentOnboardingSerializer(serializers.ModelSerializer):
    """
    Deterministic serializer for student onboarding.

    Every validation rule is explicit and machine-enforceable.
    Invalid input is rejected rather than interpreted.
    """

    STUDENT_ID_PATTERN = r"^STU-\d{4}-\d{6}$"
    PHONE_PATTERN = r"^\+\d{12}$"
    NAME_PATTERN = r"^[A-Za-zÀ-ÖØ-öø-ÿ' -]+$"

    APPROVED_COURSES = (
        "Computer Science",
        "Information Technology",
        "Electrical Engineering",
        "Mechanical Engineering",
        "Civil Engineering",
        "Business Administration",
        "Mathematics",
        "Physics",
    )

    student_id = serializers.CharField(
        min_length=16,
        max_length=16,
        validators=[
            RegexValidator(
                regex=STUDENT_ID_PATTERN,
                message=(
                    "Student identification must use the format "
                    "STU-YYYY-NNNNNN."
                ),
            )
        ],
        trim_whitespace=True,
    )

    full_name = serializers.CharField(
        min_length=2,
        max_length=100,
        validators=[
            RegexValidator(
                regex=NAME_PATTERN,
                message=(
                    "Full name may contain only alphabetic characters, "
                    "spaces, apostrophes, and hyphens."
                ),
            )
        ],
        trim_whitespace=True,
    )

    age = serializers.IntegerField(
        min_value=14,
        max_value=100,
        strict=True,
    )

    email = serializers.EmailField(
        max_length=254,
        trim_whitespace=True,
    )

    phone_number = serializers.CharField(
        min_length=13,
        max_length=13,
        validators=[
            RegexValidator(
                regex=PHONE_PATTERN,
                message=(
                    "Phone number must contain a plus sign followed by "
                    "exactly twelve digits."
                ),
            )
        ],
        trim_whitespace=True,
    )

    course = serializers.ChoiceField(
        choices=APPROVED_COURSES
    )

    has_previous_education = serializers.BooleanField(
        required=True,
        allow_null=False,
        strict=True,
    )

    has_required_documents = serializers.BooleanField(
        required=True,
        allow_null=False,
        strict=True,
    )

    consent_given = serializers.BooleanField(
        required=True,
        allow_null=False,
        strict=True,
    )

    class Meta:
        model = Student
        fields = (
            "student_id",
            "full_name",
            "age",
            "email",
            "phone_number",
            "course",
            "has_previous_education",
            "has_required_documents",
            "consent_given",
        )
        extra_kwargs = {
            "student_id": {"required": True},
            "full_name": {"required": True},
            "age": {"required": True},
            "email": {"required": True},
            "phone_number": {"required": True},
            "course": {"required": True},
        }

    def validate(self, attrs):
        """
        Apply deterministic cross-field rules.
        """

        if attrs["consent_given"] is not True:
            raise serializers.ValidationError(
                {
                    "consent_given": (
                        "Student onboarding requires explicit consent."
                    )
                }
            )

        if (
            attrs["has_previous_education"] is True
            and attrs["has_required_documents"] is False
        ):
            raise serializers.ValidationError(
                {
                    "has_required_documents": (
                        "Required documents must be provided when "
                        "previous education is declared."
                    )
                }
            )

        return attrs