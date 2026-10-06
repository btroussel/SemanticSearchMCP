"""Shared model options and validation for the local embedding runtime."""

from typing import Literal

from pydantic import BaseModel, ConfigDict, field_validator

DEFAULT_MAX_TOKENS = 4096
MIN_MAX_TOKENS = 256
MODEL_MAX_TOKENS = 8192
DIMENSIONS = (128, 256, 512, 768)
IMAGE_TOKENS = (70, 140, 280, 560, 1120)
QUERY_PROMPTS = {"code": "CodeRetrieval", "search": "SearchQuery",
                 "question_answering": "QuestionAnswering", "fact_checking": "FactChecking"}


def validate_max_tokens(value: int) -> int:
    if type(value) is not int or not MIN_MAX_TOKENS <= value <= MODEL_MAX_TOKENS:
        raise ValueError(f"Maximum input tokens must be an integer from {MIN_MAX_TOKENS} to {MODEL_MAX_TOKENS}")
    return value


class ModelSettings(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)

    max_tokens: int = DEFAULT_MAX_TOKENS
    dimensions: int = 768
    precision: Literal["float32", "bfloat16"] = "float32"
    images: bool = True
    image_tokens: int = 280
    query_task: Literal["auto", "code", "search", "question_answering", "fact_checking"] = "auto"

    @field_validator("max_tokens", mode="before")
    @classmethod
    def token_limit(cls, value):
        return validate_max_tokens(value)

    @field_validator("dimensions", "image_tokens")
    @classmethod
    def discrete_option(cls, value, info):
        choices = DIMENSIONS if info.field_name == "dimensions" else IMAGE_TOKENS
        if value not in choices:
            raise ValueError(f"{info.field_name} must be one of {choices}")
        return value
