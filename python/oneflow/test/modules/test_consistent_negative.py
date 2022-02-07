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

import oneflow as flow
import oneflow.unittest


from oneflow.test_utils.automated_test_util import *


@autotest(check_graph=False)
def _test_negative(test_case, placement, sbp):
    ndim = random(2, 5).to(int).value()
    shape = [8 for _ in range(ndim)]
    x = random_tensor(ndim, *shape).to_consistent(placement, sbp)
    return torch.negative(x)


@unittest.skip("b2s not support 0 size")
@autotest(check_graph=False)
def _test_negative_with_0_size(test_case, placement, sbp):
    x = random_tensor(3, 8, 8, 0).to_consistent(placement, sbp)
    return torch.negative(x)


class TestNegative(flow.unittest.TestCase):
    @consistent
    def test_negative(test_case):
        for placement in all_placement():
            for sbp in all_sbp(placement, max_dim=2):
                _test_negative(test_case, placement, sbp)
                _test_negative_with_0_size(test_case, placement, sbp)


if __name__ == "__main__":
    unittest.main()
