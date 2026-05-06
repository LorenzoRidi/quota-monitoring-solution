/*
Copyright 2023 Google LLC

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
*/
package functions;

import static com.google.common.truth.Truth.assertThat;

import org.junit.Test;
import org.junit.runner.RunWith;
import org.junit.runners.JUnit4;

@RunWith(JUnit4.class)
public class ScanProjectQuotasHelperTest {

  @Test
  public void testParseThreshold_integerString() {
    assertThat(ScanProjectQuotasHelper.parseThreshold("80")).isEqualTo(80);
    assertThat(ScanProjectQuotasHelper.parseThreshold("  95  ")).isEqualTo(95);
  }

  @Test
  public void testParseThreshold_ratioString() {
    assertThat(ScanProjectQuotasHelper.parseThreshold("0.8")).isEqualTo(80);
    assertThat(ScanProjectQuotasHelper.parseThreshold("0.85")).isEqualTo(85);
    assertThat(ScanProjectQuotasHelper.parseThreshold("1.0")).isEqualTo(100);
    assertThat(ScanProjectQuotasHelper.parseThreshold("0.0")).isEqualTo(0);
    assertThat(ScanProjectQuotasHelper.parseThreshold("0.999")).isEqualTo(100); // Rounded
  }

  @Test
  public void testParseThreshold_doubleString() {
    assertThat(ScanProjectQuotasHelper.parseThreshold("80.0")).isEqualTo(80);
    assertThat(ScanProjectQuotasHelper.parseThreshold("85.5")).isEqualTo(86); // Rounded
  }

  @Test
  public void testParseThreshold_nullAndEmpty() {
    assertThat(ScanProjectQuotasHelper.parseThreshold(null)).isEqualTo(80);
    assertThat(ScanProjectQuotasHelper.parseThreshold("")).isEqualTo(80);
    assertThat(ScanProjectQuotasHelper.parseThreshold("   ")).isEqualTo(80);
  }

  @Test
  public void testParseThreshold_invalidFormat() {
    assertThat(ScanProjectQuotasHelper.parseThreshold("abc")).isEqualTo(80);
    assertThat(ScanProjectQuotasHelper.parseThreshold("invalid_10")).isEqualTo(80);
  }
}
