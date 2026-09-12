def build_dcyn_library(validated_data):
    """
    Convert validated onboarding data into a binary Yes/No
    decision library.
    """

    return {
        "previous_education": (
            "YES"
            if validated_data["has_previous_education"]
            else "NO"
        ),
        "required_documents": (
            "YES"
            if validated_data["has_required_documents"]
            else "NO"
        ),
        "consent": (
            "YES"
            if validated_data["consent_given"]
            else "NO"
        ),
    }