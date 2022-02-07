"""
Copyright 2020 The OneFlow Authors. All rights reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
"""

import unittest
from collections import OrderedDict

import numpy as np
from test_util import GenArgList

import oneflow as flow
import oneflow.unittest

from oneflow.test_utils.automated_test_util import *

def test_empty_impl(test_case, ndim, placement, sbp):
    dims = [random(1, 4).to(int).value() * 8 for i in range(ndim)]
    x = flow.empty((*dims), placement=placement, sbp=sbp)
    test_case.assertTrue(x.shape == flow.Size(dims))
    test_case.assertTrue(x.placement == placement)
    test_case.assertTrue(x.sbp == sbp)

class TestEmptyConsistent(flow.unittest.TestCase):
    @consistent
    def test_empty(test_case):
        # random ndim in range [1,5]
        ndim = random(1, 6).to(int).value()
        for placement in all_placement():
            for sbp in all_sbp(placement, max_dim=ndim):
                test_empty_impl(test_case, ndim, placement, sbp)


if __name__ == "__main__":
    unittest.main()
