import os
import shutil
from pathlib import Path
from typing import Any, Dict

import pytest

from .chalk.runner import Chalk
from .utils.bin import sha256
from .utils.log import get_logger
from .utils.validate import (
    MAGIC,
    ArtifactInfo,
    validate_chalk_report,
    validate_extracted_chalk,
    validate_virtual_chalk,
)

logger = get_logger()

PYTHONFILES = Path(__file__).parent / "data" / "python"


@pytest.mark.parametrize(
    "test_file",
    [
        "sample_1",
        "sample_2",
        "sample_3",
        "sample_4",
    ],
)
def test_virtual_valid(tmp_data_dir: Path, chalk: Chalk, test_file: str):
    files = os.listdir(PYTHONFILES / test_file)
    artifact_info = {}
    for file in files:
        file_path = PYTHONFILES / test_file / file
        # top level files only, ignoring __pycache__
        if os.path.isfile(file_path):
            shutil.copy(file_path, tmp_data_dir)
            artifact_info[str(tmp_data_dir / file)] = ArtifactInfo(
                type="Python", hash=sha256(file_path)
            )

    # chalk reports generated by insertion, json array that has one element
    chalk_reports = chalk.insert(artifact=tmp_data_dir, virtual=True)
    assert len(chalk_reports) == 1
    chalk_report = chalk_reports[0]

    # check chalk report
    validate_chalk_report(
        chalk_report=chalk_report, artifact_map=artifact_info, virtual=True
    )

    # array of json chalk objects as output, of which we are only expecting one
    extract_outputs = chalk.extract(artifact=tmp_data_dir)
    assert len(extract_outputs) == 1
    extract_output = extract_outputs[0]

    validate_extracted_chalk(
        extracted_chalk=extract_output, artifact_map=artifact_info, virtual=True
    )
    validate_virtual_chalk(
        tmp_data_dir=tmp_data_dir, artifact_map=artifact_info, virtual=True
    )


@pytest.mark.parametrize(
    "test_file",
    [
        "sample_1",
        "sample_2",
        "sample_3",
        "sample_4",
    ],
)
def test_nonvirtual_valid(tmp_data_dir: Path, chalk: Chalk, test_file: str):
    files = os.listdir(PYTHONFILES / test_file)
    artifact_info = {}
    shebang_check = {}
    shebang = "#!"
    for file in files:
        file_path = PYTHONFILES / test_file / file
        # top level files only, ignoring __pycache__
        if os.path.isfile(file_path):
            shutil.copy(file_path, tmp_data_dir)
            artifact_info[str(tmp_data_dir / file)] = ArtifactInfo(
                type="Python", hash=sha256(file_path)
            )
            text = (tmp_data_dir / file).read_text().splitlines()
            if len(text) > 1 and shebang in text[0]:
                shebang_check[str(tmp_data_dir / file)] = True
            else:
                shebang_check[str(tmp_data_dir / file)] = False

    # chalk reports generated by insertion, json array that has one element
    chalk_reports = chalk.insert(artifact=tmp_data_dir, virtual=False)
    assert len(chalk_reports) == 1
    chalk_report = chalk_reports[0]

    # check chalk report
    validate_chalk_report(
        chalk_report=chalk_report, artifact_map=artifact_info, virtual=False
    )

    # array of json chalk objects as output, of which we are only expecting one
    extract_outputs = chalk.extract(artifact=tmp_data_dir)
    assert len(extract_outputs) == 1
    extract_output = extract_outputs[0]

    validate_extracted_chalk(
        extracted_chalk=extract_output, artifact_map=artifact_info, virtual=False
    )
    validate_virtual_chalk(
        tmp_data_dir=tmp_data_dir, artifact_map=artifact_info, virtual=False
    )

    # check that first line shebangs are not clobbered in non-virtual chalk
    for file in os.listdir(tmp_data_dir):
        text = (tmp_data_dir / file).read_text().splitlines()

        shebang_expected = shebang_check[str(tmp_data_dir / file)]
        assert shebang_expected == text[0].startswith(shebang)

        # chalk mark with MAGIC expected in last line

        assert text[-1].startswith("#"), "second line must be comment for chalk"
        assert MAGIC in text[-1], "missing MAGIC indicating that this is chalked"
